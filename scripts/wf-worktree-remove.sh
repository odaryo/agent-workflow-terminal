#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # 実行時に解決するパスのため静的解析では追跡できない
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
使い方: wf-worktree-remove.sh <target> [--force] [--dry-run]

worktree を削除し、安全に削除できる場合はローカルブランチも削除する。
target はパス、worktree ディレクトリ名、またはブランチ名で指定できる。
  --force     安全確認の警告を承知して worktree の削除を続行する
              locked worktree を削除する場合は2回指定する
  --dry-run   安全確認後、実行するはずの内容を表示する
  -h, --help  このヘルプを表示
EOF
}

target_arg=""
target_arg_path=""
force=0
dry_run=0
end_options=0

while [[ $# -gt 0 ]]; do
  if [[ "$end_options" -eq 1 ]]; then
    [[ -z "$target_arg" ]] || die "引数が多すぎます: $1"
    target_arg="$1"
    [[ ! -d "$target_arg" ]] || target_arg_path=$(cd -- "$target_arg" && pwd -P)
    shift
    continue
  fi
  case "$1" in
    --force)
      force=$((force + 1))
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    --)
      end_options=1
      shift
      ;;
    -*) die "不明な引数です: $1" ;;
    *)
      [[ -z "$target_arg" ]] || die "引数が多すぎます: $1"
      target_arg="$1"
      [[ ! -d "$target_arg" ]] || target_arg_path=$(cd -- "$target_arg" && pwd -P)
      shift
      ;;
  esac
done

repo_root_cd
require_cmd git gh
[[ -n "$target_arg" ]] || die "削除対象を指定してください"

worktree_output=$(git worktree list --porcelain) \
  || die "worktree 一覧を取得できませんでした (git worktree list --porcelain)"
worktree_output+=$'\n\n'

paths=()
canonical_paths=()
branches=()
heads=()
record_path=""
record_branch=""
record_head=""
while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ -z "$line" ]]; then
    if [[ -n "$record_path" ]]; then
      paths+=("$record_path")
      canonical_paths+=("$(cd -- "$record_path" 2>/dev/null && pwd -P || printf '%s' "$record_path")")
      branches+=("$record_branch")
      heads+=("$record_head")
    fi
    record_path=""
    record_branch=""
    record_head=""
    continue
  fi
  case "$line" in
    "worktree "*) record_path=${line#worktree } ;;
    "HEAD "*) record_head=${line#HEAD } ;;
    "branch refs/heads/"*) record_branch=${line#branch refs/heads/} ;;
  esac
done <<<"$worktree_output"

matches=()
i=0
while [[ "$i" -lt "${#paths[@]}" ]]; do
  if [[ -n "$target_arg_path" && "$target_arg_path" == "${canonical_paths[$i]}" ]] \
    || [[ "$target_arg" == "$(basename -- "${paths[$i]}")" ]] \
    || [[ "$target_arg" == "${branches[$i]}" ]]; then
    matches+=("$i")
  fi
  i=$((i + 1))
done

[[ ${#matches[@]} -gt 0 ]] || die "一致する worktree が見つかりません: $target_arg"
[[ ${#matches[@]} -eq 1 ]] || die "複数の worktree に一致しました: $target_arg"
match=${matches[0]}
target_path=${canonical_paths[$match]}
branch=${branches[$match]}
head_oid=${heads[$match]}
main_canonical=${canonical_paths[0]}

[[ "$target_path" != "$main_canonical" ]] || die "メイン作業ツリーは削除できません: $target_path"
cwd_canonical=$(pwd -P)
case "$cwd_canonical/" in
  "$target_path/"*) die "対象 worktree の中からは削除できません: $target_path" ;;
esac

warnings=()
if [[ -d "$target_path" ]]; then
  status=$(git -C "$target_path" status --porcelain --untracked-files=normal) \
    || die "未コミット変更を確認できませんでした: $target_path"
  [[ -z "$status" ]] || warnings+=("未コミットの変更があります")

  ignored=$(git -C "$target_path" status --porcelain --ignored --untracked-files=all) \
    || die "ignored ファイルを確認できませんでした: $target_path"
  if grep -q '^!! ' <<<"$ignored"; then
    info "注意: ignored ファイルは worktree とともに削除されます"
  fi
else
  info "作業ツリーのディレクトリは既に存在しません: $target_path"
fi

merged_oids=""
if [[ -n "$branch" ]]; then
  load_merged_pr_heads
  merged_oids=$(merged_pr_head_oids "$branch")
  local_head_oid=$(git rev-parse "refs/heads/$branch") \
    || die "ローカルブランチの head を取得できませんでした: $branch"

  remote_head_oid=""
  if git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    remote_head_oid=$(git rev-parse "refs/remotes/origin/$branch") \
      || die "リモート追跡ブランチの head を取得できませんでした: origin/$branch"
  fi
  if [[ "$remote_head_oid" != "$local_head_oid" ]] \
    && { [[ -z "$merged_oids" ]] || ! grep -qxF "$local_head_oid" <<<"$merged_oids"; }; then
    warnings+=("ローカルにしか無いコミットがあります")
  fi

  # squash-only 運用ではブランチ先端が origin/main の祖先にならないため、
  # `git merge-base --is-ancestor` ではなくマージ済み PR の head OID と照合する。
  if [[ -z "$merged_oids" ]] || ! grep -qxF "$local_head_oid" <<<"$merged_oids"; then
    warnings+=("マージ済み PR の head と一致しません")
  fi
else
  local_head_oid=""
  if ! git merge-base --is-ancestor "$head_oid" origin/main 2>/dev/null; then
    warnings+=("detached HEAD に origin/main から到達できないコミットがあります")
  fi
fi

if [[ ${#warnings[@]} -gt 0 ]]; then
  info "安全確認で次の問題が見つかりました:"
  for warning in "${warnings[@]}"; do
    info "  - $warning"
  done
  [[ "$force" -gt 0 ]] || die "削除を中止しました (--force で続行できます)"
fi

remove_command=(git worktree remove)
i=0
while [[ "$i" -lt "$force" ]]; do
  remove_command+=(--force)
  i=$((i + 1))
done
remove_command+=(-- "$target_path")
if [[ "$dry_run" -eq 1 ]]; then
  info "[dry-run] ${remove_command[*]}"
  if [[ -n "$branch" && -n "$merged_oids" ]] \
    && grep -qxF "$local_head_oid" <<<"$merged_oids"; then
    info "[dry-run] git branch -D $branch"
  else
    info "ローカルブランチは安全に削除できないため残します: ${branch:-detached HEAD}"
  fi
  exit 0
fi

remove_error=""
if ! remove_error=$("${remove_command[@]}" 2>&1); then
  info "git worktree remove に失敗しました: $remove_error"
  refreshed=$(git worktree list --porcelain) \
    || die "削除失敗後の worktree 一覧を取得できませんでした"
  record=$(awk -v path="$target_path" '
    $1 == "worktree" { current = substr($0, 10); text = $0 "\n"; next }
    NF == 0 { if (current == path) { printf "%s", text; exit }; current = ""; text = ""; next }
    { text = text $0 "\n" }
    END { if (current == path) printf "%s", text }
  ' <<<"$refreshed")
  if [[ -z "$record" ]]; then
    die "対象の登録は消えています (ファイルが残っている可能性があります): $target_path"
  elif grep -Eq '^locked( |$)' <<<"$record"; then
    die "対象は locked worktree です。削除するには --force を2回指定してください: $target_path"
  elif grep -Eq '^(prunable|bare)( |$)' <<<"$record"; then
    die "対象の登録は残っていますが prunable / bare のため手当てが必要です: $target_path"
  else
    die "対象の登録は残っているため、問題を解消してやり直せます: $target_path"
  fi
fi
[[ -z "$remove_error" ]] || info "$remove_error"
info "worktree を削除しました: $target_path"

if [[ -n "$branch" && -n "$merged_oids" ]] \
  && grep -qxF "$local_head_oid" <<<"$merged_oids"; then
  branch_delete_error=""
  if ! branch_delete_error=$(git branch -D "$branch" 2>&1); then
    die "worktree は削除済みですが、ローカルブランチ '$branch' の削除に失敗しました: $branch_delete_error"
  fi
  [[ -z "$branch_delete_error" ]] || info "$branch_delete_error"
  info "ローカルブランチを削除しました: $branch"
elif [[ -n "$branch" ]]; then
  info "ローカルブランチはマージ済み PR の head と一致しないため残しました: $branch"
else
  info "detached HEAD のためローカルブランチの削除はありません"
fi

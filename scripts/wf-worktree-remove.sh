#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # 実行時に解決するパスのため静的解析では追跡できない
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
使い方: wf-worktree-remove.sh <target> [--force] [--dry-run] [--kill-session]

worktree を削除し、安全に削除できる場合はローカルブランチも削除する。
target はパス、worktree ディレクトリ名、またはブランチ名で指定できる。
アプリが作った tmux session (設計書 §3.5) は既定では削除せず、残っていれば名前と
削除コマンドを表示する。
  --force     安全確認の警告を承知して worktree の削除を続行する
              2回指定すると locked worktree も削除できる
  --dry-run   安全確認後、実行するはずの内容を表示する
  --kill-session
              対応する tmux session も削除する (完全一致指定。存在しなければ何もしない)
  --           以降を target として扱う (後ろにフラグは指定できない)
  -h, --help  このヘルプを表示
EOF
}

target_arg=""
target_arg_path=""
force=0
dry_run=0
kill_session=0
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
    --kill-session)
      kill_session=1
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
# python3 は session 名の導出にしか使わないので必須にしない (無いときの扱いは
# resolve_session_name を参照)。worktree の削除そのものを道連れにしないため。
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

[[ ${#matches[@]} -gt 0 ]] \
  || die "一致する worktree が見つかりません: $target_arg (detached HEAD の場合はパスまたは worktree ディレクトリ名で指定してください)"
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

# 安定 ID (§3.5) の入手は lib.sh の awt_worktree_admin_dir に置いてある (規則とその根拠は
# そちらのコメント)。ここで導出するのは、worktree を消した後では引けなくなるものがあるため。
session_name=""
session_error=""
resolve_session_name() {
  local admin_dir status=0
  admin_dir=$(awt_worktree_admin_dir "${paths[$match]}" "$target_path") || status=$?
  case "$status" in
    0) ;;
    1) session_error="この worktree の管理ディレクトリを見つけられませんでした" ;;
    2) session_error="管理ディレクトリが複数一致しました" ;;
    *) session_error="共通 git ディレクトリを取得できませんでした" ;;
  esac
  [[ "$status" -eq 0 ]] || return 0
  # python3 は名前の導出にしか使わない。無いことを worktree 削除そのものの失敗にはしないが、
  # 「session が無かった」と区別できるように理由は残す (--kill-session のときだけ die する)。
  command -v python3 >/dev/null 2>&1 || {
    session_error="python3 が見つかりません (session 名の導出にのみ必要)"
    return 0
  }
  session_name=$(awt_tmux_session_name "$admin_dir") || {
    session_name=""
    session_error="安定 ID からの導出に失敗しました: $admin_dir"
  }
}
resolve_session_name

# 導出できなかったことは削除の**前**に言う。後回しにすると、報告を受けた時点では
# `<共通 git dir>/worktrees/` の登録も消えていて、名前を復元する手段が残らない。
[[ -z "$session_error" ]] || info "tmux session 名を導出できませんでした: $session_error"
# 名前が分からないまま撃つことはしない。worktree を消してから失敗させるのではなく、何もしないうちに
# 止める (--kill-session を外せば削除自体は続行できる、と伝えるため)。
[[ "$kill_session" -eq 0 || -z "$session_error" ]] \
  || die "--kill-session を指定しましたが、${session_error}。--kill-session を外せば worktree の削除だけは実行できます"

# 対象 session が在るかどうか。素の `tmux` を使うので、見に行く server は `$TMUX` (tmux pane の
# 中なら、その pane の server) が無ければ既定 server。アプリが session を作るのも同じ選び方
# なので、通常はアプリのものと同じ server を見る。tmux が無い・server が動いていない場合は
# has-session が失敗するので、そのまま「無い」として扱う。
session_exists() {
  [[ -n "$session_name" ]] || return 1
  command -v tmux >/dev/null 2>&1 || return 1
  tmux has-session -t "=$session_name" 2>/dev/null
}

# 消さない側を既定にしている。worktree の削除条件 (未コミット変更が無いなど) は「その worktree で
# 動いている agent が居ない」ことを意味せず、session の破棄は取り返しがつかないため (Issue #343)。
report_session() {
  local tense="$1"
  # 導出できなかった場合は削除の前に報告済み。
  session_exists || return 0
  # `$tense` を波括弧で囲むのは、直後の全角句点まで変数名として読まれるため
  # (実測 bash 3.2.57 / macOS: `tense。: unbound variable` で落ちた)。
  info "tmux session '$session_name' が${tense}。消すには: tmux kill-session -t '=$session_name'"
}

# --kill-session で撃つ相手が居なかったときに出す。無言で終わると、もともと session が無かったのか、
# 導出した名前が実際の session と違っていたのかを利用者が区別できない。
report_no_session() {
  info "対応する tmux session はありません (何もしませんでした): $session_name"
}

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
local_head_oid=""
delete_branch=0
worktree_has_unique_commits() {
  if git merge-base --is-ancestor "$1" origin/main 2>/dev/null; then
    return 1
  fi
  return 0
}

if ! worktree_has_unique_commits "$head_oid"; then
  [[ -z "$branch" ]] || delete_branch=1
elif [[ -n "$branch" ]]; then
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
    warnings+=("ローカル head が origin/$branch およびマージ済み PR の head と一致しません")
  fi

  # squash-only 運用ではブランチ先端が origin/main の祖先にならないため、
  # `git merge-base --is-ancestor` ではなくマージ済み PR の head OID と照合する。
  if [[ -z "$merged_oids" ]] || ! grep -qxF "$local_head_oid" <<<"$merged_oids"; then
    warnings+=("マージ済み PR の head と一致しません")
  else
    delete_branch=1
  fi
else
  warnings+=("detached HEAD に origin/main から到達できないコミットがあります")
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
  if [[ "$delete_branch" -eq 1 ]]; then
    info "[dry-run] git branch -D $branch"
  else
    info "ローカルブランチは安全に削除できないため残します: ${branch:-detached HEAD}"
  fi
  if [[ "$kill_session" -eq 1 ]]; then
    # 実行時と同じ判断・同じ出力にする (導出できていない場合は上で既に止まっている)。
    if session_exists; then
      info "[dry-run] tmux kill-session -t '=$session_name'"
    else
      report_no_session
    fi
  else
    report_session "残ります"
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
    if [[ -n "$branch" ]]; then
      die "worktree 登録は既に消えているため、このスクリプトでは以後扱えません。残っているのは '$target_path' のディレクトリだけです。失敗原因 (権限など) を解消してから、そのディレクトリを手で削除してください。ローカルブランチ '$branch' は残っています。マージ済みなら scripts/wf-cleanup-branches.sh --yes で削除できます"
    fi
    die "worktree 登録は既に消えているため、このスクリプトでは以後扱えません。残っているのは '$target_path' のディレクトリだけです。失敗原因 (権限など) を解消してから、そのディレクトリを手で削除してください。detached HEAD のためローカルブランチはありません"
  elif grep -Eq '^locked( |$)' <<<"$record"; then
    die "対象は locked worktree です。削除するには --force を2回指定してください: $target_path"
  elif grep -Eq '^(prunable|bare)( |$)' <<<"$record"; then
    die "対象の登録は prunable / bare のまま残っています。原因を解消して同じコマンドを再実行すれば片付けられます: $target_path"
  else
    die "対象の登録は残っているため、問題を解消してやり直せます: $target_path"
  fi
fi
[[ -z "$remove_error" ]] || info "$remove_error"
info "worktree を削除しました: $target_path"

if [[ "$delete_branch" -eq 1 ]]; then
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

if [[ "$kill_session" -eq 1 ]]; then
  if session_exists; then
    # 必ず `=` の完全一致で、自分が導出した名前だけを撃つ。前方一致や `kill-server` は
    # 使わない (CLAUDE.md「外部 CLI を計測するときの作法」)。
    kill_error=""
    if ! kill_error=$(tmux kill-session -t "=$session_name" 2>&1); then
      die "worktree は削除済みですが、tmux session '$session_name' の削除に失敗しました: $kill_error"
    fi
    [[ -z "$kill_error" ]] || info "$kill_error"
    info "tmux session を削除しました: $session_name"
  else
    report_no_session
  fi
else
  report_session "残っています"
fi

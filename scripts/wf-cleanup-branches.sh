#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # 実行時に解決するパスのため静的解析では追跡できない
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
使い方: wf-cleanup-branches.sh [--yes] [--dry-run]
       wf-cleanup-branches.sh --discard <branch>... [--yes] [--dry-run]

既定はマージ済み PR の head ブランチ (main と現在のブランチを除く) の削除。
リモートが自動削除済みでローカルだけ残ったものと、リモートに残っているものの双方が対象。
  --yes        削除を実行する (省略時は一覧表示のみ)
  --dry-run    --yes が指定されていても削除しない
  --discard    PR を1つも持たないブランチを名前指定で削除する (使い捨ての診断ブランチ用)。
               PR が存在するブランチは state を問わず拒否する — マージ済みなら既定の経路が、
               未マージなら人が扱うべきで、いずれもこの経路の対象ではない
  -h, --help   このヘルプを表示
EOF
}

do_delete=0
dry_run=0
discard=0
discard_branches=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes)
      do_delete=1
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --discard)
      discard=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      die "不明な引数です: $1"
      ;;
    *)
      [[ "$discard" -eq 1 ]] || die "不明な引数です: $1"
      discard_branches+=("$1")
      shift
      ;;
  esac
done

repo_root_cd
require_cmd git gh

git fetch --prune origin

current_branch=$(git rev-parse --abbrev-ref HEAD)

# 他の worktree が checkout 中のブランチは `git branch -D` が拒否する。既定の経路では一覧に
# 出してから失敗させないよう事前に除外するが、これは best-effort — rebase が停止中の worktree は
# `branch` 行ではなく `detached` を出力するのに削除は拒否される (git 2.50.1 で実測)。
# 取りこぼしは後段の削除ループが per-item で許容する。--discard は事前検査で弾く。
checked_out=$(git worktree list --porcelain | awk '$1 == "branch" { print substr($2, 12) }')

if [[ "$discard" -eq 1 ]]; then
  [[ ${#discard_branches[@]} -gt 0 ]] || die "--discard にはブランチ名を1つ以上指定してください"

  # 削除の前に全件を検査する。1件でも条件を満たさなければ何も消さない — 一部だけ消えた
  # 状態は、呼び出し側が「消えた分」を知らないまま再実行することになるため。
  for b in "${discard_branches[@]}"; do
    case "$b" in
      main | "$current_branch") die "'$b' は main か現在のブランチのため削除できません" ;;
    esac
    if grep -qxF "$b" <<<"$checked_out"; then
      die "'$b' は worktree が checkout 中です。先に wf-worktree-remove.sh を実行してください"
    fi
    prs=$(gh pr list --head "$b" --state all --limit 1 --json number --jq '.[].number')
    if [[ -n "$prs" ]]; then
      die "'$b' は PR #$prs を持つため --discard の対象外です (マージ済みなら --yes だけで消せます)"
    fi
    if ! git show-ref --verify --quiet "refs/heads/$b" \
      && ! git show-ref --verify --quiet "refs/remotes/origin/$b"; then
      die "'$b' はローカルにもリモートにも存在しません"
    fi
  done

  info "PR を持たないブランチを削除します:"
  for b in "${discard_branches[@]}"; do
    info "  $b"
  done

  if [[ "$do_delete" -ne 1 ]]; then
    info "削除するには --yes を指定してください"
    exit 0
  fi

  failed=0
  for b in "${discard_branches[@]}"; do
    if git show-ref --verify --quiet "refs/heads/$b"; then
      if [[ "$dry_run" -eq 1 ]]; then
        info "[dry-run] git branch -D $b"
      elif git branch -D "$b"; then
        info "ローカルを削除しました: $b"
      else
        info "警告: ローカル '$b' の削除に失敗しました"
        failed=1
      fi
    fi
    if git show-ref --verify --quiet "refs/remotes/origin/$b"; then
      if [[ "$dry_run" -eq 1 ]]; then
        info "[dry-run] git push origin --delete $b"
      elif git push origin --delete "$b"; then
        info "リモートを削除しました: origin/$b"
      else
        info "警告: 'origin/$b' の削除に失敗しました"
        failed=1
      fi
    fi
  done
  [[ "$failed" -eq 0 ]] || die "削除できなかったブランチがあります (上の警告を確認してください)"
  exit 0
fi

load_merged_pr_heads

# ローカルとリモートの両方を候補にする。GitHub の deleteBranchOnMerge が有効だと
# マージ時点でリモート ref が消えるため、リモートだけを見ると常に候補ゼロになる
# (Issue #70 で実測)。逆に自動削除が効かなかった場合はリモートだけが残る。
# `git branch -r` ではなく for-each-ref なのは、前者が origin 以外のリモートも列挙し、
# その ref を後段の `git rev-parse refs/remotes/origin/...` が解決できず set -e で
# 中断するため (隔離リポジトリで実測)。origin 配下に限定すれば発生しない。
candidates=$(
  {
    git for-each-ref --format='%(refname:strip=2)' refs/heads/
    git for-each-ref --format='%(refname:strip=3)' refs/remotes/origin/
  } | sort -u
)

local_branches=()
remote_branches=()
while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  case "$name" in
    HEAD | main | "$current_branch") continue ;;
  esac
  # 同名ブランチが複数 PR で使われた場合はいずれかの head と一致すればマージ済みとみなす。
  # どの head とも一致しない = マージ後に push されたコミットがあるということで、
  # 削除すると未マージの作業を失うためスキップする。
  merged_oids=$(merged_pr_head_oids "$name")
  [[ -n "$merged_oids" ]] || continue

  # rev-parse を引数位置に置いているため失敗しても set -e は発火しないが、
  # 直前の show-ref で ref の存在を保証しており、仮に空になっても不一致 = スキップに倒れる。
  if git show-ref --verify --quiet "refs/heads/$name"; then
    if grep -qxF "$name" <<<"$checked_out"; then
      info "警告: '$name' は他の worktree が checkout 中のためローカル削除をスキップしました"
    elif grep -qxF "$(git rev-parse "refs/heads/$name")" <<<"$merged_oids"; then
      local_branches+=("$name")
    else
      info "警告: ローカル '$name' はマージ済み PR の head と一致しないためスキップしました (マージ後のコミットあり)"
    fi
  fi

  if git show-ref --verify --quiet "refs/remotes/origin/$name"; then
    if grep -qxF "$(git rev-parse "refs/remotes/origin/$name")" <<<"$merged_oids"; then
      remote_branches+=("$name")
    else
      info "警告: リモート 'origin/$name' はマージ済み PR の head と一致しないためスキップしました (マージ後の push あり)"
    fi
  fi
done <<<"$candidates"

if [[ ${#local_branches[@]} -eq 0 && ${#remote_branches[@]} -eq 0 ]]; then
  info "削除対象なし"
  exit 0
fi

if [[ ${#local_branches[@]} -gt 0 ]]; then
  info "マージ済みローカルブランチ:"
  for b in "${local_branches[@]}"; do
    info "  $b"
  done
fi
if [[ ${#remote_branches[@]} -gt 0 ]]; then
  info "マージ済みリモートブランチ:"
  for b in "${remote_branches[@]}"; do
    info "  origin/$b"
  done
fi

if [[ "$do_delete" -ne 1 ]]; then
  info "削除するには --yes を指定してください"
  exit 0
fi

if [[ "$dry_run" -eq 1 ]]; then
  for b in ${local_branches[@]+"${local_branches[@]}"}; do
    info "[dry-run] git branch -D $b"
  done
  for b in ${remote_branches[@]+"${remote_branches[@]}"}; do
    info "[dry-run] git push origin --delete $b"
  done
  exit 0
fi

# squash マージ後は元コミットが main の祖先にならず `git branch -d` が通らないため -D を使う。
# -D は元コミットを到達不能にするが、上のループで head OID 一致を必須にしているので
# 失われるのはコミットだけで、内容は squash コミットとして main に入っている。
#
# 1件の失敗で set -e に中断させない。中断すると一覧に出した対象の一部だけが消え、
# しかもローカル側の失敗でリモート側のループごと飛ぶ (rebase 停止中 worktree、
# ネットワーク断、保護ブランチなど)。全件試みたうえで終了ステータスに反映する。
failed=0
deleted_local=()
deleted_remote=()
for b in ${local_branches[@]+"${local_branches[@]}"}; do
  if git branch -D "$b"; then
    deleted_local+=("$b")
  else
    info "警告: ローカル '$b' の削除に失敗しました"
    failed=1
  fi
done
for b in ${remote_branches[@]+"${remote_branches[@]}"}; do
  if git push origin --delete "$b"; then
    deleted_remote+=("$b")
  else
    info "警告: 'origin/$b' の削除に失敗しました"
    failed=1
  fi
done
[[ ${#deleted_local[@]} -eq 0 ]] || info "ローカルを削除しました: ${deleted_local[*]}"
[[ ${#deleted_remote[@]} -eq 0 ]] || info "リモートを削除しました: ${deleted_remote[*]}"
[[ "$failed" -eq 0 ]] || die "削除できなかったブランチがあります (上の警告を確認してください)"

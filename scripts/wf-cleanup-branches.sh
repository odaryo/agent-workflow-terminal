#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # 実行時に解決するパスのため静的解析では追跡できない
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
使い方: wf-cleanup-branches.sh [--yes] [--dry-run]

マージ済み PR の head ブランチ (main と現在のブランチを除く) を削除する。
リモートが自動削除済みでローカルだけ残ったものと、リモートに残っているものの双方が対象。
  --yes       削除を実行する (省略時は一覧表示のみ)
  --dry-run   --yes が指定されていても削除しない
  -h, --help  このヘルプを表示
EOF
}

do_delete=0
dry_run=0

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
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "不明な引数です: $1"
      ;;
  esac
done

repo_root_cd
require_cmd git gh

git fetch --prune origin

current_branch=$(git rev-parse --abbrev-ref HEAD)

# squash マージではブランチ先端が origin/main の祖先にならないため、
# `git branch --merged origin/main` はマージ済みブランチを検出できない
# (squash-only 運用の本リポジトリでは削除候補が1件も出ない。Issue #45 で実測)。
# 代わりにマージ済み PR の head を gh から取得し、ローカル/リモートの ref と突き合わせる。
# 直近200件より古い PR のブランチは対象外だが、消しすぎ側には倒れない。
# --base main は必須。base が main 以外の PR (stacked PR の子など) は、親が main に
# 入らないまま閉じられると squash コミットが main から到達不能なままになるため。
merged_head_tsv=$(gh pr list --state merged --limit 200 --base main --json headRefName,headRefOid \
  --jq '.[] | .headRefName + "\t" + .headRefOid') \
  || die "マージ済み PR の取得に失敗しました (gh pr list)"

# 他の worktree が checkout 中のブランチは `git branch -D` が拒否する。一覧に出してから
# 失敗させないよう事前に除外するが、これは best-effort — rebase が停止中の worktree は
# `branch` 行ではなく `detached` を出力するのに削除は拒否される (git 2.50.1 で実測)。
# 取りこぼしは後段の削除ループが per-item で許容する。
checked_out=$(git worktree list --porcelain | awk '$1 == "branch" { print substr($2, 12) }')

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
  # `$1 ""` は文字列比較の強制。awk は -v 代入値が数値に見えると数値比較に切り替わり、
  # `007` と `7` のようなブランチ名が一致してしまう。
  merged_oids=$(awk -F '\t' -v name="$name" '$1 "" == name "" { print $2 }' <<<"$merged_head_tsv")
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

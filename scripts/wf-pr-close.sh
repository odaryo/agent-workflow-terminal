#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # 実行時に解決するパスのため静的解析では追跡できない
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
使い方: wf-pr-close.sh <PR番号> [-c "<理由>"] [--delete-branch] [--dry-run]

マージせずに PR を閉じる (計測用・実験用の一時 PR の後始末)。
  -c, --comment      閉じる理由をコメントとして残す
  --delete-branch    リモートの head ブランチも削除する
  --dry-run          実行せず、実行するはずの内容を表示する
  -h, --help         このヘルプを表示
EOF
}

pr_number=""
comment=""
delete_branch=0
dry_run=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c | --comment)
      require_value "-c/--comment" "$#"
      comment="$2"
      shift 2
      ;;
    --delete-branch)
      delete_branch=1
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
      [[ -z "$pr_number" ]] || die "引数が多すぎます: $1"
      pr_number="$1"
      shift
      ;;
  esac
done

repo_root_cd
require_cmd git gh

[[ -n "$pr_number" ]] || die "PR番号を指定してください"
[[ "$pr_number" =~ ^[0-9]+$ ]] || die "PR番号は数値で指定してください: $pr_number"

pr_line=$(gh pr view "$pr_number" --json state,title,headRefName \
  --jq '[.state, .title, .headRefName] | join("\t")') \
  || die "PR #$pr_number の情報取得に失敗しました"
IFS=$'\t' read -r pr_state pr_title pr_head <<<"$pr_line"

# MERGED を閉じ直そうとするのは番号の取り違えを疑うべき状況なので、黙って
# 成功させずに止める。
[[ "$pr_state" == "OPEN" ]] || die "PR #$pr_number は OPEN ではありません (state=$pr_state)"

args=(pr close "$pr_number")
[[ -z "$comment" ]] || args+=(--comment "$comment")
[[ "$delete_branch" -eq 0 ]] || args+=(--delete-branch)

if [[ "$dry_run" -eq 1 ]]; then
  info "[dry-run] gh ${args[*]}"
  info "[dry-run] 対象: #$pr_number \"$pr_title\" (head=$pr_head)"
  exit 0
fi

gh "${args[@]}" || die "PR #$pr_number のクローズに失敗しました"
info "PR #$pr_number をクローズしました (head=$pr_head)"

# gh の --delete-branch はリモートとローカルの両方を消すが、対象がカレント
# ブランチだったり未 push コミットがあると黙ってローカルだけ残ることがある。
# wf-cleanup-branches.sh はマージ済み PR しか見ないので、残骸は回収されない。
if [[ "$delete_branch" -eq 1 ]] && git show-ref --verify --quiet "refs/heads/$pr_head"; then
  info "ローカルブランチ '$pr_head' は残っています (削除するなら git branch -D '$pr_head')"
fi

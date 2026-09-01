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
  --delete-branch    head ブランチもリモート・ローカルの順で削除する。
                     CLOSED 済みの PR に対して指定すると、削除だけをやり直す
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

pr_line=$(gh pr view "$pr_number" --json state,title,headRefName,isCrossRepository \
  --jq '[.state, .title, .headRefName, (.isCrossRepository|tostring)] | join("\t")') \
  || die "PR #$pr_number の情報取得に失敗しました"
IFS=$'\t' read -r pr_state pr_title pr_head pr_is_fork <<<"$pr_line"

need_close=1
case "$pr_state" in
  OPEN) ;;
  # close 済みでもブランチが残るのは、gh の --delete-branch が close 後の削除で
  # 失敗した後 (下記参照) など。やり直せないと残骸を回収する手段が無くなる。
  CLOSED)
    [[ "$delete_branch" -eq 1 ]] || die "PR #$pr_number は既に CLOSED です"
    need_close=0
    info "PR #$pr_number は既に CLOSED です。ブランチ削除のみ行います"
    ;;
  # MERGED を閉じ直そうとするのは番号の取り違えを疑うべき状況なので、黙って
  # 成功させずに止める。
  *) die "PR #$pr_number は OPEN ではありません (state=$pr_state)" ;;
esac

repo_nwo=$(nwo)
remote_ref="repos/$repo_nwo/git/refs/heads/$pr_head"

if [[ "$dry_run" -eq 1 ]]; then
  info "[dry-run] 対象: #$pr_number \"$pr_title\" (head=$pr_head, state=$pr_state)"
  if [[ "$need_close" -eq 1 ]]; then
    if [[ -n "$comment" ]]; then
      info "[dry-run] gh pr close $pr_number --comment \"$comment\""
    else
      info "[dry-run] gh pr close $pr_number"
    fi
  fi
  if [[ "$delete_branch" -eq 1 ]]; then
    if [[ "$pr_is_fork" == "true" ]]; then
      info "[dry-run] fork からの PR のためリモートブランチは削除しない"
    else
      info "[dry-run] gh api -X DELETE $remote_ref"
    fi
    info "[dry-run] git branch -D $pr_head (ローカルに存在する場合のみ)"
  fi
  exit 0
fi

if [[ "$need_close" -eq 1 ]]; then
  close_args=(pr close "$pr_number")
  # gh 自身の --delete-branch は使わない。close → ローカル削除 → リモート削除の順で
  # 実行し、ローカル削除の失敗でそのまま非ゼロ終了するため (gh 2.92.0 close.go で確認)、
  # 「PR は閉じたがリモートブランチだけ残り、しかも gh は失敗を返す」状態になる。
  # 1タスク=1worktree 運用ではローカル削除は worktree に checkout 済みで日常的に
  # 失敗する (git branch -D は worktree 使用中のブランチを拒否。実測済み)。
  [[ -z "$comment" ]] || close_args+=(--comment "$comment")
  gh "${close_args[@]}" || die "PR #$pr_number のクローズに失敗しました"
  info "PR #$pr_number をクローズしました (head=$pr_head)"
fi

[[ "$delete_branch" -eq 1 ]] || exit 0

# ここから先の失敗は close 済みが前提なので、失敗メッセージ自体に「PR は閉じている」
# ことと再実行手段を含める。wf-pr-merge.sh のような ERR トラップは使わない —
# 以降の失敗は全て die 経由で、die の exit では ERR トラップが発火しないため (実測)。

if [[ "$pr_is_fork" == "true" ]]; then
  info "fork からの PR のためリモートブランチは削除しません"
elif gh api -X DELETE "$remote_ref" >/dev/null 2>&1; then
  info "リモートブランチ '$pr_head' を削除しました"
else
  # 既に無い (404) のか権限・保護ルールで拒否されたのかを区別する。
  if gh api "$remote_ref" >/dev/null 2>&1; then
    die "PR #$pr_number は閉じましたが、リモートブランチ '$pr_head' の削除に失敗しました (再実行: scripts/wf-pr-close.sh $pr_number --delete-branch)"
  fi
  info "リモートブランチ '$pr_head' は既にありません"
fi

if ! git show-ref --verify --quiet "refs/heads/$pr_head"; then
  exit 0
fi
if delete_out=$(git branch -D "$pr_head" 2>&1); then
  info "ローカルブランチ '$pr_head' を削除しました"
else
  # 別 worktree に checkout されているブランチは削除できない (実測)。worktree を
  # 消すかどうかは作業中かに依るのでスクリプトでは判断せず、事実だけ知らせる。
  info "警告: ローカルブランチ '$pr_head' を削除できませんでした: $delete_out"
  info "worktree で使用中の場合は worktree を片付けたうえで scripts/wf-pr-close.sh $pr_number --delete-branch を再実行してください"
fi

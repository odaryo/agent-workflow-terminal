#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # 実行時に解決するパスのため静的解析では追跡できない
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
使い方: wf-ci-rerun.sh <PR番号> [--dry-run]

PR の head commit で失敗した workflow run の、失敗したジョブだけを再実行する。
変更と無関係な揺れ (負荷で時間閾値を外れるテストなど) で落ちたときに使う。
  --dry-run   実行せず、再実行するはずの run を表示する
  -h, --help  このヘルプを表示
EOF
}

pr_number=""
dry_run=0

while [[ $# -gt 0 ]]; do
  case "$1" in
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
require_cmd gh

[[ -n "$pr_number" ]] || die "PR番号を指定してください"
[[ "$pr_number" =~ ^[0-9]+$ ]] || die "PR番号は数値で指定してください: $pr_number"

pr_line=$(gh pr view "$pr_number" --json state,headRefOid --jq '[.state, .headRefOid] | join("\t")') \
  || die "PR #$pr_number の情報取得に失敗しました"
IFS=$'\t' read -r pr_state head_oid <<<"$pr_line"
[[ "$pr_state" == "OPEN" ]] || die "PR #$pr_number は OPEN ではありません (state=$pr_state)"

# head commit で絞る。branch で絞ると、push 前の古い commit の失敗 run まで拾い、
# 今の head の結果を変えない再実行をしてしまう。
failed_runs=$(gh run list --commit "$head_oid" --status failure \
  --json databaseId,workflowName --jq '.[] | "\(.databaseId)\t\(.workflowName)"') \
  || die "workflow run の一覧取得に失敗しました"
[[ -n "$failed_runs" ]] || die "PR #$pr_number の head ($head_oid) に失敗した workflow run はありません"

while IFS=$'\t' read -r run_id workflow_name; do
  if [[ "$dry_run" -eq 1 ]]; then
    info "[dry-run] gh run rerun $run_id --failed ($workflow_name)"
    continue
  fi
  gh run rerun "$run_id" --failed || die "run $run_id ($workflow_name) の再実行に失敗しました"
  info "run $run_id ($workflow_name) の失敗ジョブを再実行しました"
done <<<"$failed_runs"

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # 実行時に解決するパスのため静的解析では追跡できない
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
使い方: wf-ci-rerun.sh (<PR番号> | --main) [--dry-run]

PR の head commit で失敗した workflow run の、失敗したジョブだけを再実行する。
--main では、workflow ごとに main への push で最後に走った run を対象にする。
ランナーを確保できずに取り消されたジョブ (cancelled) も、再実行の対象に入る。
実行中の run に失敗ジョブがあれば、再実行せず完了を待つよう案内する。
変更と無関係な揺れ (負荷で時間閾値を外れるテストなど) で落ちたときに使う。
  --main      PR ではなく、main への push の最新の run を対象にする
  --dry-run   実行せず、再実行するはずの run を表示する
  -h, --help  このヘルプを表示
EOF
}

pr_number=""
main_mode=0
dry_run=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      dry_run=1
      shift
      ;;
    --main)
      main_mode=1
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

if [[ "$main_mode" -eq 1 ]]; then
  [[ -z "$pr_number" ]] || die "--main と PR番号は同時に指定できません"
  # main の先頭の commit では絞らない。paths-ignore に当たる docs だけの push では CI が走らず、
  # 直前の commit の失敗 run が main の最新の CI のまま残る。
  target="main"
else
  [[ -n "$pr_number" ]] || die "PR番号か --main を指定してください"
  [[ "$pr_number" =~ ^[0-9]+$ ]] || die "PR番号は数値で指定してください: $pr_number"

  pr_line=$(gh pr view "$pr_number" --json state,headRefOid --jq '[.state, .headRefOid] | join("\t")') \
    || die "PR #$pr_number の情報取得に失敗しました"
  IFS=$'\t' read -r pr_state head_oid <<<"$pr_line"
  [[ "$pr_state" == "OPEN" ]] || die "PR #$pr_number は OPEN ではありません (state=$pr_state)"
  target="PR #$pr_number"
fi

# head commit で絞る。branch で絞ると、push 前の古い commit の失敗 run まで拾い、
# 今の head の結果を変えない再実行をしてしまう。
# --status failure は conclusion に一致し、ジョブ失敗後も実行中の run を拾わない。
# #429 の計測では、他ジョブが終わるまで20秒間 conclusion が null だった。
if [[ "$main_mode" -eq 1 ]]; then
  runs=$(gh run list --branch main --event push --limit 50 \
    --json databaseId,workflowName,status,conclusion,createdAt \
    --jq 'group_by(.workflowName) | map(max_by(.createdAt)) | .[]
      | "\(.databaseId)\t\(.status)\t\(if .conclusion == "" or .conclusion == null then "-" else .conclusion end)\t\(.workflowName)"') \
    || die "workflow run の一覧取得に失敗しました"
else
  runs=$(gh run list --commit "$head_oid" \
    --json databaseId,workflowName,status,conclusion \
    --jq '.[] | "\(.databaseId)\t\(.status)\t\(if .conclusion == "" or .conclusion == null then "-" else .conclusion end)\t\(.workflowName)"') \
    || die "workflow run の一覧取得に失敗しました"
fi

rerun_count=0
pending_failure=0
while IFS=$'\t' read -r run_id run_status conclusion workflow_name; do
  [[ -n "$run_id" ]] || continue
  if [[ "$conclusion" == "failure" ]]; then
    if [[ "$dry_run" -eq 1 ]]; then
      info "[dry-run] gh run rerun $run_id --failed ($workflow_name)"
    else
      gh run rerun "$run_id" --failed || die "run $run_id ($workflow_name) の再実行に失敗しました"
      info "run $run_id ($workflow_name) の失敗ジョブを再実行しました"
    fi
    rerun_count=$((rerun_count + 1))
  elif [[ "$run_status" != "completed" ]]; then
    failed_jobs=$(gh run view "$run_id" --json jobs \
      --jq '.jobs[] | select(.conclusion == "failure") | .name') \
      || die "run $run_id ($workflow_name) のジョブ取得に失敗しました"
    if [[ -n "$failed_jobs" ]]; then
      info "run $run_id ($workflow_name) の失敗ジョブ:"
      info "$failed_jobs"
      info "run はまだ実行中なので、完了してから再実行してください"
      pending_failure=1
    fi
  fi
done <<<"$runs"

[[ "$rerun_count" -eq 0 ]] || exit 0
[[ "$pending_failure" -eq 0 ]] || exit 1
if [[ "$main_mode" -eq 1 ]]; then
  die "main への push の最新の workflow run に、失敗したものはありません"
fi
die "$target の head ($head_oid) に失敗した workflow run はありません"

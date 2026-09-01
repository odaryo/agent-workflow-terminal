#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # 実行時に解決するパスのため静的解析では追跡できない
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
使い方: wf-project-status.sh <issue番号> "<status>" [--dry-run]

Project "agent-workflow-terminal" 上の Issue の Status を更新する。
  --dry-run   実行せず、解決済みの値と実行するはずのコマンドを表示する
  -h, --help  このヘルプを表示
EOF
}

issue_number=""
status=""
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
      if [[ -z "$issue_number" ]]; then
        issue_number="$1"
      elif [[ -z "$status" ]]; then
        status="$1"
      else
        die "引数が多すぎます: $1"
      fi
      shift
      ;;
  esac
done

repo_root_cd
require_cmd git gh

[[ -n "$issue_number" ]] || die "Issue番号を指定してください"
[[ "$issue_number" =~ ^[0-9]+$ ]] || die "Issue番号は数値で指定してください: $issue_number"
[[ -n "$status" ]] || die "status を指定してください"

project_title="agent-workflow-terminal"
repo_nwo=$(nwo)
owner="${repo_nwo%%/*}"

project_line=$(gh project list --owner "$owner" --format json \
  --jq ".projects[] | select(.title == \"$project_title\") | [(.number|tostring), .id] | join(\"\t\")")
[[ -n "$project_line" ]] || die "Project '$project_title' が owner '$owner' に見つかりません"
IFS=$'\t' read -r project_number project_id <<<"$project_line"

item_id=$(gh project item-list "$project_number" --owner "$owner" --format json --limit 200 \
  --jq ".items[] | select(.content.number == $issue_number) | .id")
[[ -n "$item_id" ]] || die "Issue #$issue_number が Project '$project_title' 内に見つかりません"

field_id=$(gh project field-list "$project_number" --owner "$owner" --format json \
  --jq '.fields[] | select(.name == "Status") | .id')
[[ -n "$field_id" ]] || die "Project '$project_title' に Status フィールドが見つかりません"

option_id=$(gh project field-list "$project_number" --owner "$owner" --format json \
  --jq ".fields[] | select(.name == \"Status\") | .options[]? | select(.name == \"$status\") | .id")

if [[ -z "$option_id" ]]; then
  available_names=$(gh project field-list "$project_number" --owner "$owner" --format json \
    --jq '.fields[] | select(.name == "Status") | .options[]?.name')
  available=""
  while IFS= read -r opt; do
    [[ -n "$opt" ]] || continue
    if [[ -z "$available" ]]; then
      available="$opt"
    else
      available="$available, $opt"
    fi
  done <<<"$available_names"
  die "不明な status です: '$status' (利用可能な選択肢: $available)"
fi

if [[ "$dry_run" -eq 1 ]]; then
  info "[dry-run] project=$project_number ($project_id) item=$item_id field=$field_id option=$option_id"
  info "[dry-run] gh project item-edit --project-id $project_id --id $item_id --field-id $field_id --single-select-option-id $option_id"
  exit 0
fi

gh project item-edit \
  --project-id "$project_id" \
  --id "$item_id" \
  --field-id "$field_id" \
  --single-select-option-id "$option_id" >/dev/null

info "Issue #$issue_number の Status を '$status' に更新しました"

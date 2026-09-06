#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # 実行時に解決するパスのため静的解析では追跡できない
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
使い方: wf-milestone.sh create <title> [-d <description>] [--dry-run]
        wf-milestone.sh close <title> [--dry-run]
        wf-milestone.sh assign <title> <issue番号>... [--dry-run]
        wf-milestone.sh list

マイルストーン (= docs/roadmap.md のフェーズ) を作成・クローズし、Issue を割り当てる。
  create   同名のマイルストーンがあれば何もしない
  close    Open の Issue が残っていてもクローズする (GitHub の仕様)。事前に assign で移すこと
  assign   Issue のマイルストーンを <title> へ付け替える
  list     Open のマイルストーンと Open/Closed 件数を表示する
  --dry-run  実行せず、実行するはずのコマンドを表示する
  -h, --help このヘルプを表示

フェーズの定義と進行状況は docs/roadmap.md が正本。マイルストーンはその写しで、
Issue 一覧をフェーズで絞り込むためだけに使う。
EOF
}

[[ $# -gt 0 ]] || {
  usage
  exit 1
}

subcommand="$1"
shift

title=""
description=""
dry_run=0
issues=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d | --description)
      require_value "-d/--description" "$#"
      description="$2"
      shift 2
      ;;
    --dry-run)
      dry_run=1
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
      if [[ -z "$title" ]]; then
        title="$1"
      elif [[ "$subcommand" == "assign" ]]; then
        [[ "$1" =~ ^[0-9]+$ ]] || die "Issue番号は数値で指定してください: $1"
        issues+=("$1")
      else
        die "引数が多すぎます: $1"
      fi
      shift
      ;;
  esac
done

repo_root_cd
require_cmd git gh jq

milestone_number() {
  # gh milestone サブコマンドは存在しないため REST API を直接使う。
  # state=all で引くのは、閉じたマイルストーンへの再 create を黙って重複させないため。
  gh api --paginate "repos/$(nwo)/milestones?state=all&per_page=100" \
    --jq ".[] | select(.title == \"$1\") | .number" | head -n 1
}

case "$subcommand" in
  list)
    gh api --paginate "repos/$(nwo)/milestones?state=open&per_page=100" \
      --jq '.[] | "\(.number)\t\(.title)\topen=\(.open_issues) closed=\(.closed_issues)"'
    ;;
  create)
    [[ -n "$title" ]] || die "マイルストーン名を指定してください"
    if [[ -n "$(milestone_number "$title")" ]]; then
      info "マイルストーンは既にあります: $title"
      exit 0
    fi
    display="gh api repos/$(nwo)/milestones -f title=$(printf '%q' "$title")"
    [[ -z "$description" ]] || display+=" -f description=$(printf '%q' "$description")"
    if [[ "$dry_run" -eq 1 ]]; then
      info "[dry-run] $display"
      exit 0
    fi
    args=(-f "title=$title")
    [[ -z "$description" ]] || args+=(-f "description=$description")
    gh api "repos/$(nwo)/milestones" "${args[@]}" --jq '.number' >/dev/null
    info "マイルストーンを作成しました: $title"
    ;;
  close)
    [[ -n "$title" ]] || die "マイルストーン名を指定してください"
    number=$(milestone_number "$title")
    [[ -n "$number" ]] || die "マイルストーンが見つかりません: $title"
    if [[ "$dry_run" -eq 1 ]]; then
      info "[dry-run] gh api -X PATCH repos/$(nwo)/milestones/$number -f state=closed"
      exit 0
    fi
    gh api -X PATCH "repos/$(nwo)/milestones/$number" -f state=closed --jq '.state' >/dev/null
    info "マイルストーンをクローズしました: $title"
    ;;
  assign)
    [[ -n "$title" ]] || die "マイルストーン名を指定してください"
    [[ ${#issues[@]} -gt 0 ]] || die "Issue番号を1つ以上指定してください"
    [[ -n "$(milestone_number "$title")" ]] || die "マイルストーンが見つかりません: $title"
    for issue in "${issues[@]}"; do
      if [[ "$dry_run" -eq 1 ]]; then
        info "[dry-run] gh issue edit $issue --milestone $(printf '%q' "$title")"
        continue
      fi
      gh issue edit "$issue" --milestone "$title" >/dev/null
      info "Issue #$issue → $title"
    done
    ;;
  *)
    die "不明なサブコマンドです: $subcommand"
    ;;
esac

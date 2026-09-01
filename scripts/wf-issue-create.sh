#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # 実行時に解決するパスのため静的解析では追跡できない
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
使い方: wf-issue-create.sh -t "<title>" -b "<body>" [-l <label>]... [-m "<milestone>"] [--no-project] [--dry-run]

Issue を作成する。body には "## 概要" と "## 完了条件" の両見出しが必須。
  -t, --title      Issue タイトル
  -b, --body       Issue 本文
  -l, --label      ラベル (複数指定可)
  -m, --milestone  マイルストーン
  --no-project     Project (agent-workflow-terminal) へ追加しない
  --dry-run        実行せず、実行するはずの内容を表示する
  -h, --help       このヘルプを表示
EOF
}

title=""
body=""
labels=()
milestone=""
no_project=0
dry_run=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t | --title)
      require_value "-t/--title" "$#"
      title="$2"
      shift 2
      ;;
    -b | --body)
      require_value "-b/--body" "$#"
      body="$2"
      shift 2
      ;;
    -l | --label)
      require_value "-l/--label" "$#"
      labels+=("$2")
      shift 2
      ;;
    -m | --milestone)
      require_value "-m/--milestone" "$#"
      milestone="$2"
      shift 2
      ;;
    --no-project)
      no_project=1
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

[[ -n "$title" ]] || die "タイトル (-t) を指定してください"
[[ -n "$body" ]] || die "本文 (-b) を指定してください"

grep -qF '## 概要' <<<"$body" || die "本文に '## 概要' 見出しがありません"
grep -qF '## 完了条件' <<<"$body" || die "本文に '## 完了条件' 見出しがありません"

project_name="agent-workflow-terminal"

args=(issue create --title "$title" --body "$body")
display="gh issue create --title \"$title\" --body <inline>"

if [[ ${#labels[@]} -gt 0 ]]; then
  for label in "${labels[@]}"; do
    args+=(--label "$label")
    display+=" --label \"$label\""
  done
fi

if [[ -n "$milestone" ]]; then
  args+=(--milestone "$milestone")
  display+=" --milestone \"$milestone\""
fi

if [[ "$no_project" -ne 1 ]]; then
  args+=(--project "$project_name")
  display+=" --project \"$project_name\""
fi

if [[ "$dry_run" -eq 1 ]]; then
  info "[dry-run] $display"
  exit 0
fi

gh "${args[@]}"

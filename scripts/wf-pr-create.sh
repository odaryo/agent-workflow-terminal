#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # 実行時に解決するパスのため静的解析では追跡できない
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
使い方: wf-pr-create.sh -t "<title>" (-b "<body>" | -F <bodyfile>) [-B <base>=main] [--dry-run]

現在のブランチから PR を作成する (Project には追加しない)。
  -t, --title      PR タイトル
  -b, --body       PR 本文
  -F, --body-file  PR 本文ファイル
  -B, --base       ベースブランチ (既定: main)
  --dry-run        実行せず、実行するはずの内容を表示する
  -h, --help       このヘルプを表示
EOF
}

title=""
body=""
body_file=""
base="main"
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
    -F | --body-file)
      require_value "-F/--body-file" "$#"
      body_file="$2"
      shift 2
      ;;
    -B | --base)
      require_value "-B/--base" "$#"
      base="$2"
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
    *)
      die "不明な引数です: $1"
      ;;
  esac
done

repo_root_cd
require_cmd git gh

[[ -n "$title" ]] || die "タイトル (-t) を指定してください"
# squash マージ時にこのタイトルがそのまま main のコミットログになる (Issue #43)。
require_conventional_title "$title" "PR タイトル"
if [[ -n "$body" && -n "$body_file" ]]; then
  die "-b と -F は同時に指定できません"
fi
if [[ -z "$body" && -z "$body_file" ]]; then
  die "-b または -F で本文を指定してください"
fi

current_branch=$(git rev-parse --abbrev-ref HEAD)
[[ "$current_branch" != "main" ]] || die "main ブランチから PR は作成できません"

has_upstream=1
git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1 || has_upstream=0

if [[ "$has_upstream" -eq 0 ]]; then
  if [[ "$dry_run" -eq 1 ]]; then
    info "[dry-run] push が必要です: git push -u origin $current_branch"
  else
    git push -u origin "$current_branch"
  fi
fi

if [[ "$dry_run" -eq 1 ]]; then
  if [[ -n "$body_file" ]]; then
    info "[dry-run] gh pr create --title \"$title\" --body-file \"$body_file\" --base \"$base\""
  else
    info "[dry-run] gh pr create --title \"$title\" --body <inline> --base \"$base\""
  fi
  exit 0
fi

if [[ -n "$body_file" ]]; then
  gh pr create --title "$title" --body-file "$body_file" --base "$base"
else
  gh pr create --title "$title" --body "$body" --base "$base"
fi

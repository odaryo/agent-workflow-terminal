#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # 実行時に解決するパスのため静的解析では追跡できない
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
使い方: wf-issue-comment.sh <issue番号> (-b "<body>" | -F <bodyfile>) [--dry-run]

Issue にコメントを投稿する。
  -b, --body       コメント本文
  -F, --body-file  コメント本文ファイル ("-" で標準入力)
  --dry-run        実行せず、投稿するはずの本文を表示する
  -h, --help       このヘルプを表示

用途の例: Codex へ渡す spec を、渡す前に Issue へ残す (CLAUDE.md
「What survives a `/clear`」)。spec がセッション scratchpad にしか無いと
`/clear` で辿れなくなる。
EOF
}

issue_number=""
body=""
body_file=""
dry_run=0

while [[ $# -gt 0 ]]; do
  case "$1" in
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
      [[ -z "$issue_number" ]] || die "引数が多すぎます: $1"
      issue_number="$1"
      shift
      ;;
  esac
done

repo_root_cd
require_cmd git gh

[[ -n "$issue_number" ]] || die "Issue番号を指定してください"
[[ "$issue_number" =~ ^[0-9]+$ ]] || die "Issue番号は数値で指定してください: $issue_number"
[[ -n "$body" || -n "$body_file" ]] || die "-b/--body か -F/--body-file を指定してください"
[[ -z "$body" || -z "$body_file" ]] || die "-b/--body と -F/--body-file は同時に指定できません"

if [[ -n "$body_file" ]]; then
  if [[ "$body_file" = "-" ]]; then
    body="$(cat)"
  else
    [[ -f "$body_file" ]] || die "本文ファイルがありません: $body_file"
    body="$(cat "$body_file")"
  fi
fi
[[ -n "$body" ]] || die "コメント本文が空です"

if [[ "$dry_run" -eq 1 ]]; then
  info "[dry-run] gh issue comment $issue_number --body-file - へ次を渡す:"
  printf '%s\n' "$body" >&2
  exit 0
fi

# gh の出力 (コメントの URL) を捨てない。投稿先を目視で確認できるようにする。
printf '%s' "$body" | gh issue comment "$issue_number" --body-file -

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # 実行時に解決するパスのため静的解析では追跡できない
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
使い方: wf-pr-reply.sh <PR番号> --reply-to <comment-databaseId> -b "<body>" [--dry-run]
       wf-pr-reply.sh <PR番号> --issue -b "<body>" [--dry-run]

--reply-to はレビューコメントへスレッド返信、--issue は conversation へのトップレベルコメント。
両モードは排他。
  --dry-run   実行せず、実行するはずの内容を表示する
  -h, --help  このヘルプを表示
EOF
}

pr_number=""
reply_to=""
issue_mode=0
body=""
dry_run=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reply-to)
      require_value "--reply-to" "$#"
      reply_to="$2"
      shift 2
      ;;
    --issue)
      issue_mode=1
      shift
      ;;
    -b | --body)
      require_value "-b/--body" "$#"
      body="$2"
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
[[ -n "$body" ]] || die "本文 (-b) を指定してください"

if [[ -n "$reply_to" && "$issue_mode" -eq 1 ]]; then
  die "--reply-to と --issue は同時に指定できません"
fi
if [[ -z "$reply_to" && "$issue_mode" -ne 1 ]]; then
  die "--reply-to <databaseId> または --issue を指定してください"
fi

if [[ -n "$reply_to" ]]; then
  [[ "$reply_to" =~ ^[0-9]+$ ]] || die "--reply-to は数値の databaseId で指定してください: $reply_to"
  repo_nwo=$(nwo)

  if [[ "$dry_run" -eq 1 ]]; then
    info "[dry-run] gh api -X POST repos/$repo_nwo/pulls/$pr_number/comments -f body=<body> -F in_reply_to=$reply_to"
    exit 0
  fi

  gh api -X POST "repos/$repo_nwo/pulls/$pr_number/comments" \
    -f body="$body" \
    -F in_reply_to="$reply_to" >/dev/null
  info "レビューコメント (databaseId=$reply_to) へ返信しました"
else
  if [[ "$dry_run" -eq 1 ]]; then
    info "[dry-run] gh pr comment $pr_number --body <body>"
    exit 0
  fi

  gh pr comment "$pr_number" --body "$body" >/dev/null
  info "PR #$pr_number にコメントしました"
fi

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # 実行時に解決するパスのため静的解析では追跡できない
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
使い方: wf-issue-close.sh <issue番号> (-b "<body>" | -F <bodyfile>) [--not-planned] [--dry-run]

理由をコメントとして残してから Issue をクローズする。
  -b, --body       クローズ理由 (必須)
  -F, --body-file  クローズ理由のファイル ("-" で標準入力)
  --not-planned    "not planned" として閉じる (既定は "completed")
  --dry-run        実行せず、実行するはずの内容を表示する
  -h, --help       このヘルプを表示

通常の Issue は PR 本文の `Closes #N` で自動的に閉じる。このスクリプトが要るのは
PR を伴わない Issue — 実地確認や調査のように、成果がコミットではなく判断であるもの。
理由を必須にしているのは、閉じた判断が Issue に残っていないと後から辿れないため。
EOF
}

issue_number=""
body=""
body_file=""
not_planned=0
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
    --not-planned)
      not_planned=1
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
[[ -n "$body" || -n "$body_file" ]] || die "-b/--body か -F/--body-file でクローズ理由を指定してください"
[[ -z "$body" || -z "$body_file" ]] || die "-b/--body と -F/--body-file は同時に指定できません"

if [[ -n "$body_file" ]]; then
  if [[ "$body_file" = "-" ]]; then
    body="$(cat)"
  else
    [[ -f "$body_file" ]] || die "本文ファイルがありません: $body_file"
    body="$(cat "$body_file")"
  fi
fi
[[ -n "$body" ]] || die "クローズ理由が空です"

state=$(gh issue view "$issue_number" --json state --jq .state) \
  || die "Issue を取得できません: #$issue_number"
[[ "$state" = "OPEN" ]] || die "Issue #$issue_number は既に $state です"

reason="completed"
[[ "$not_planned" -eq 0 ]] || reason="not planned"

if [[ "$dry_run" -eq 1 ]]; then
  info "[dry-run] gh issue close $issue_number --reason \"$reason\" へ次の理由を添える:"
  printf '%s\n' "$body" >&2
  exit 0
fi

printf '%s' "$body" | gh issue comment "$issue_number" --body-file -
gh issue close "$issue_number" --reason "$reason"

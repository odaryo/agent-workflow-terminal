#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # 実行時に解決するパスのため静的解析では追跡できない
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
使い方: wf-issue-edit.sh <issue番号> [-a "<text>" | -A <file> | -b "<body>" | -B <file>] [-t "<title>"] [--dry-run]

Issue の本文とタイトルを更新する。本文は追記が既定で、置換は明示指定が要る。
  -a, --append        本文の末尾へ追記する (既存の本文は保持)
  -A, --append-file   追記内容をファイルから読む
  -b, --body          本文を丸ごと置き換える
  -B, --body-file     置き換える本文をファイルから読む
  -t, --title         Issue タイトルを変更する
      --dry-run       実行せず、実行するはずの内容を表示する
  -h, --help          このヘルプを表示

追記を既定にしているのは wf-pr-edit.sh と同じ理由で、置換は既存の本文を丸ごと失い得るから。
要求の改訂のように経緯を残したい変更は、本文の置換より wf-issue-comment.sh を優先する。
EOF
}

issue_number=""
append=""
append_file=""
body=""
body_file=""
title=""
dry_run=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -a | --append)
      require_value "-a/--append" "$#"
      append="$2"
      shift 2
      ;;
    -A | --append-file)
      require_value "-A/--append-file" "$#"
      append_file="$2"
      shift 2
      ;;
    -b | --body)
      require_value "-b/--body" "$#"
      body="$2"
      shift 2
      ;;
    -B | --body-file)
      require_value "-B/--body-file" "$#"
      body_file="$2"
      shift 2
      ;;
    -t | --title)
      require_value "-t/--title" "$#"
      title="$2"
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
      [[ -z "$issue_number" ]] || die "Issue番号は1つだけ指定してください: $issue_number, $1"
      issue_number="$1"
      shift
      ;;
  esac
done

repo_root_cd
require_cmd git gh

[[ -n "$issue_number" ]] || die "Issue番号を指定してください"
[[ "$issue_number" =~ ^[0-9]+$ ]] || die "Issue番号は数値で指定してください: $issue_number"

selected=0
for value in "$append" "$append_file" "$body" "$body_file"; do
  [[ -n "$value" ]] && selected=$((selected + 1))
done
[[ "$selected" -le 1 ]] || die "-a / -A / -b / -B は同時に指定できません"
if [[ "$selected" -eq 0 && -z "$title" ]]; then
  die "本文 (-a/-A/-b/-B) かタイトル (-t) のいずれかを指定してください"
fi

if [[ -n "$append_file" ]]; then
  [[ -f "$append_file" ]] || die "追記内容のファイルが見つかりません: $append_file"
  append=$(cat "$append_file")
fi
if [[ -n "$body_file" ]]; then
  [[ -f "$body_file" ]] || die "本文ファイルが見つかりません: $body_file"
  body=$(cat "$body_file")
fi

# gh issue edit は PR 番号も受け付けて PR を書き換える。PR は wf-pr-edit.sh の
# Conventional Commits 検査を通すべきなので、ここでは Issue だけを対象にする。
# `gh issue view --json` には PR かどうかを返すフィールドが無い。
is_pr=$(gh api "repos/{owner}/{repo}/issues/$issue_number" --jq '.pull_request != null') \
  || die "Issue #$issue_number を取得できません"
[[ "$is_pr" == "false" ]] || die "#$issue_number は PR です。PR は scripts/wf-pr-edit.sh で編集してください"

if [[ -n "$append" ]]; then
  current_body=$(gh issue view "$issue_number" --json body --jq .body) \
    || die "Issue #$issue_number の本文を取得できません"
  # 既存本文が空でも先頭に空行が入らないようにする。
  if [[ -n "$current_body" ]]; then
    body="$current_body"$'\n\n'"$append"
  else
    body="$append"
  fi
fi

if [[ "$dry_run" -eq 1 ]]; then
  # printf '%q' は macOS の bash 3.2 で非 ASCII をバイト単位の $'\ooo' に崩すので使わない。
  [[ -z "$title" ]] || info "[dry-run] gh issue edit $issue_number --title \"$title\""
  [[ -z "$body" ]] || info "[dry-run] gh issue edit $issue_number --body <${#body} 文字>"
  exit 0
fi

# --body-file - で本文を stdin から渡す。引数に置くと本文中の改行や記号が
# シェルの引用規則に晒されるため。
if [[ -n "$body" && -n "$title" ]]; then
  printf '%s' "$body" | gh issue edit "$issue_number" --title "$title" --body-file -
elif [[ -n "$body" ]]; then
  printf '%s' "$body" | gh issue edit "$issue_number" --body-file -
else
  gh issue edit "$issue_number" --title "$title"
fi

info "Issue #$issue_number を更新しました"

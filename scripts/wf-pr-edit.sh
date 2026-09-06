#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # 実行時に解決するパスのため静的解析では追跡できない
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
使い方: wf-pr-edit.sh <PR番号> [-a "<text>" | -A <file> | -b "<body>" | -B <file>] [-t "<title>"] [--dry-run]

PR の本文とタイトルを更新する。本文は追記が既定で、置換は明示指定が要る。
  -a, --append        本文の末尾へ追記する (既存の本文は保持)
  -A, --append-file   追記内容をファイルから読む
  -b, --body          本文を丸ごと置き換える
  -B, --body-file     置き換える本文をファイルから読む
  -t, --title         PR タイトルを変更する (Conventional Commits 形式)
      --dry-run       実行せず、実行するはずの内容を表示する
  -h, --help          このヘルプを表示

追記を既定にしているのは、この script の主用途が CLAUDE.md の「レビューで棄却した指摘は
棄却理由とともに PR 本文に残す」「実測の記録を残す」であり、いずれも既存の本文へ足す操作だから。
置換は書きかけの本文を丸ごと失い得るので、-b/-B を明示したときだけ行う。
EOF
}

pr_number=""
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
      [[ -z "$pr_number" ]] || die "PR 番号は1つだけ指定してください: $pr_number, $1"
      pr_number="$1"
      shift
      ;;
  esac
done

repo_root_cd
require_cmd git gh

[[ -n "$pr_number" ]] || die "PR 番号を指定してください"
[[ "$pr_number" =~ ^[0-9]+$ ]] || die "PR 番号は数字で指定してください: $pr_number"

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

# squash マージ時に PR タイトルがそのまま main のコミットログになる (Issue #43)。
[[ -z "$title" ]] || require_conventional_title "$title" "PR タイトル"

pr_state=$(gh pr view "$pr_number" --json state --jq .state) \
  || die "PR #$pr_number を取得できません"
[[ "$pr_state" == "OPEN" ]] || die "PR #$pr_number は $pr_state です。OPEN な PR のみ編集できます"

if [[ -n "$append" ]]; then
  current_body=$(gh pr view "$pr_number" --json body --jq .body) \
    || die "PR #$pr_number の本文を取得できません"
  # 既存本文が空でも先頭に空行が入らないようにする。
  if [[ -n "$current_body" ]]; then
    body="$current_body"$'\n\n'"$append"
  else
    body="$append"
  fi
fi

if [[ "$dry_run" -eq 1 ]]; then
  [[ -z "$title" ]] || info "[dry-run] gh pr edit $pr_number --title \"$title\""
  [[ -z "$body" ]] || info "[dry-run] gh pr edit $pr_number --body <${#body} 文字>"
  exit 0
fi

# --body-file - で本文を stdin から渡す。引数に置くと本文中の改行や記号が
# シェルの引用規則に晒されるため。
if [[ -n "$body" && -n "$title" ]]; then
  printf '%s' "$body" | gh pr edit "$pr_number" --title "$title" --body-file -
elif [[ -n "$body" ]]; then
  printf '%s' "$body" | gh pr edit "$pr_number" --body-file -
else
  gh pr edit "$pr_number" --title "$title"
fi

info "PR #$pr_number を更新しました"

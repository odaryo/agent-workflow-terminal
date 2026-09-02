#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # 実行時に解決するパスのため静的解析では追跡できない
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
使い方: wf-issue-label.sh <issue番号> [--add <label>]... [--remove <label>]... [--dry-run]

Issue のラベルを付け外しする。
  --add       付けるラベル (複数指定可)
  --remove    外すラベル (複数指定可)
  --dry-run   実行せず、実行するはずのコマンドを表示する
  -h, --help  このヘルプを表示

用途の例: 設計判断が済んだ Issue から `設計判断` ラベルを外して着手可能にする
(CLAUDE.md「決定待ち」ビューの運用)。
EOF
}

issue_number=""
add_labels=()
remove_labels=()
dry_run=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --add)
      require_value "--add" "$#"
      add_labels+=("$2")
      shift 2
      ;;
    --remove)
      require_value "--remove" "$#"
      remove_labels+=("$2")
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
[[ ${#add_labels[@]} -gt 0 || ${#remove_labels[@]} -gt 0 ]] \
  || die "--add か --remove を少なくとも1つ指定してください"

# gh は --add-label "a,b" をラベル2件として解釈するため、1フラグ1ラベルの前提が崩れ、
# --dry-run の表示とも食い違う。複数指定はフラグの繰り返しで表現させる。
for label in ${add_labels[@]+"${add_labels[@]}"} ${remove_labels[@]+"${remove_labels[@]}"}; do
  [[ "$label" != *,* ]] \
    || die "ラベル名にカンマは使えません (複数指定は --add/--remove を繰り返してください): $label"
done

args=(issue edit "$issue_number")
display="gh issue edit $issue_number"
for label in ${add_labels[@]+"${add_labels[@]}"}; do
  args+=(--add-label "$label")
  display+=" --add-label $(printf '%q' "$label")"
done
for label in ${remove_labels[@]+"${remove_labels[@]}"}; do
  args+=(--remove-label "$label")
  display+=" --remove-label $(printf '%q' "$label")"
done

if [[ "$dry_run" -eq 1 ]]; then
  info "[dry-run] $display"
  exit 0
fi

# gh の出力 (Issue URL) を捨てない。--remove-label は存在しないラベルでも成功しうるため、
# 「更新しました」だけでは実際に何が起きたか分からない。
gh "${args[@]}"

info "Issue #$issue_number のラベルを更新しました"
gh issue view "$issue_number" --json labels --jq '"現在のラベル: " + ((.labels | map(.name) | join(", ")) // "")' >&2

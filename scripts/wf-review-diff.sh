#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # 実行時に解決するパスのため静的解析では追跡できない
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
使い方: wf-review-diff.sh <PR番号>
       wf-review-diff.sh --branch <name>

PR またはブランチの差分をレビュー用に表示する (読み取り専用)。
  -h, --help  このヘルプを表示
EOF
}

pr_number=""
branch=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)
      require_value "--branch" "$#"
      branch="$2"
      shift 2
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

if [[ -n "$branch" && -n "$pr_number" ]]; then
  die "PR番号 と --branch は同時に指定できません"
fi

if [[ -n "$branch" ]]; then
  require_cmd git
  git fetch origin
  echo "## git log --oneline origin/main..$branch"
  git log --oneline "origin/main..$branch"
  echo
  echo "## git diff origin/main...$branch"
  git diff "origin/main...$branch"
  exit 0
fi

[[ -n "$pr_number" ]] || die "PR番号 または --branch を指定してください"
[[ "$pr_number" =~ ^[0-9]+$ ]] || die "PR番号は数値で指定してください: $pr_number"

require_cmd git gh

echo "## PR #$pr_number"
gh pr view "$pr_number" \
  --json title,state,baseRefName,headRefName,commits \
  --jq '"title: " + .title,
        "state: " + .state,
        "base: " + .baseRefName,
        "head: " + .headRefName,
        "commits:",
        (.commits[] | "  " + (.oid[0:7]) + " " + .messageHeadline)'
echo "----------------------------------------"
gh pr diff "$pr_number"

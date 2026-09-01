#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # 実行時に解決するパスのため静的解析では追跡できない
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
使い方: wf-pr-comments.sh <PR番号>

PR の conversation コメントとレビュースレッドを表示する (読み取り専用)。
レビュースレッドの各コメントには返信 (wf-pr-reply.sh --reply-to) に使う databaseId を表示する。
  -h, --help  このヘルプを表示
EOF
}

pr_number=""

while [[ $# -gt 0 ]]; do
  case "$1" in
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

repo_nwo=$(nwo)
owner="${repo_nwo%%/*}"
repo="${repo_nwo##*/}"

# shellcheck disable=SC2016 # $owner 等は GraphQL 変数であり shell 展開させない
review_threads_query='
query($owner:String!, $repo:String!, $number:Int!) {
  repository(owner:$owner, name:$repo) {
    pullRequest(number:$number) {
      reviewThreads(first:100) {
        nodes {
          path
          line
          isResolved
          comments(first:100) {
            nodes {
              databaseId
              author { login }
              body
            }
          }
        }
      }
    }
  }
}'

conv_count=$(gh pr view "$pr_number" --json comments --jq '.comments | length')
review_threads_count=$(gh api graphql \
  -f owner="$owner" -f repo="$repo" -F number="$pr_number" -f query="$review_threads_query" \
  --jq '.data.repository.pullRequest.reviewThreads.nodes | length')

if [[ "$conv_count" -eq 0 && "$review_threads_count" -eq 0 ]]; then
  echo "コメントなし"
  exit 0
fi

echo "## conversation コメント ($conv_count 件)"
if [[ "$conv_count" -eq 0 ]]; then
  echo "コメントなし"
else
  gh pr view "$pr_number" --json comments \
    --jq '.comments[] | "[" + .author.login + " " + .createdAt + "]\n" + .body + "\n"'
fi

echo
echo "## レビュースレッド ($review_threads_count 件)"
if [[ "$review_threads_count" -eq 0 ]]; then
  echo "コメントなし"
else
  gh api graphql \
    -f owner="$owner" -f repo="$repo" -F number="$pr_number" -f query="$review_threads_query" \
    --jq '.data.repository.pullRequest.reviewThreads.nodes[] |
      "path=" + (.path // "?") + " line=" + ((.line // "?") | tostring) + " resolved=" + (.isResolved | tostring) + "\n" +
      (.comments.nodes[] | "  [databaseId=" + (.databaseId | tostring) + "] " + .author.login + ": " + .body) + "\n"'
fi

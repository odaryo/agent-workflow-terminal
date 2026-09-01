#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # 実行時に解決するパスのため静的解析では追跡できない
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
使い方: wf-cleanup-branches.sh [--yes] [--dry-run]

origin/main にマージ済みのリモートブランチ (main と現在のブランチを除く) を削除する。
  --yes       削除を実行する (省略時は一覧表示のみ)
  --dry-run   --yes が指定されていても削除しない
  -h, --help  このヘルプを表示
EOF
}

do_delete=0
dry_run=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes)
      do_delete=1
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
require_cmd git

git fetch --prune origin

current_branch=$(git rev-parse --abbrev-ref HEAD)

branches=()
while IFS= read -r raw_line; do
  branch=""
  read -r branch _ <<<"$raw_line"
  [[ -n "$branch" ]] || continue
  case "$branch" in
    origin/HEAD | origin/main | "origin/$current_branch") continue ;;
  esac
  branches+=("${branch#origin/}")
done < <(git branch -r --merged origin/main)

if [[ ${#branches[@]} -eq 0 ]]; then
  info "削除対象なし"
  exit 0
fi

info "マージ済みリモートブランチ:"
for b in "${branches[@]}"; do
  info "  $b"
done

if [[ "$do_delete" -ne 1 ]]; then
  info "削除するには --yes を指定してください"
  exit 0
fi

if [[ "$dry_run" -eq 1 ]]; then
  for b in "${branches[@]}"; do
    info "[dry-run] git push origin --delete $b"
  done
  exit 0
fi

for b in "${branches[@]}"; do
  git push origin --delete "$b"
done
info "削除しました: ${branches[*]}"

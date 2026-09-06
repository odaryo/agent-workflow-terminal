#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # 実行時に解決するパスのため静的解析では追跡できない
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
使い方: wf-worktree-create.sh <branch> [--base <ref>] [--dry-run]

命名規約に沿うブランチと worktree を作成する。
  --base <ref>  作成元 (既定: origin/main)
  --dry-run     実行せず、実行するはずの内容を表示する
  -h, --help    このヘルプを表示
EOF
}

branch=""
base="origin/main"
dry_run=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)
      require_value "--base" "$#"
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
      [[ -z "$branch" ]] || die "引数が多すぎます: $1"
      branch="$1"
      shift
      ;;
  esac
done

repo_root_cd
require_cmd git

[[ -n "$branch" ]] || die "ブランチ名を指定してください"
[[ "$branch" =~ ^(feat|fix|docs|refactor|test|chore|ci|build|perf|style|spike)/[^/]+$ ]] \
  || die "ブランチ名は <type>/<slug> 形式で指定してください: $branch"

main_worktree=$(git rev-parse --path-format=absolute --git-common-dir)
main_worktree=$(cd -- "$(dirname -- "$main_worktree")" && pwd -P)
worktrees_dir=${AWT_WORKTREES_DIR:-"$(dirname -- "$main_worktree")/awt-worktrees"}
slug=${branch#*/}
target="$worktrees_dir/$slug"

git show-ref --verify --quiet "refs/heads/$branch" \
  && die "同名のローカルブランチが既に存在します: $branch"
git show-ref --verify --quiet "refs/remotes/origin/$branch" \
  && die "同名のリモートブランチが既に存在します: origin/$branch"
[[ ! -e "$target" && ! -L "$target" ]] || die "対象ディレクトリが既に存在します: $target"

if [[ "$dry_run" -eq 1 ]]; then
  info "[dry-run] git fetch --prune origin"
  info "[dry-run] git worktree add -b $branch $target $base"
  exit 0
fi

git fetch --prune origin
git show-ref --verify --quiet "refs/remotes/origin/$branch" \
  && die "同名のリモートブランチが既に存在します: origin/$branch"
git worktree add -b "$branch" "$target" "$base" >&2
printf '%s\n' "$target"

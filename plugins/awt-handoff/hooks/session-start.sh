#!/usr/bin/env bash

exec 2>/dev/null

# GIT_* を一律には拒否しない。GIT_CEILING_DIRECTORIES のように探索の範囲だけを変えるものは、cwd からの判定を保つ。
[[ -z "${GIT_DIR+x}${GIT_WORK_TREE+x}${GIT_COMMON_DIR+x}" ]] || exit 0

inside_work_tree=$(git rev-parse --is-inside-work-tree) || exit 0
[[ "$inside_work_tree" == true ]] || exit 0

git_dir=$(git rev-parse --git-dir) || exit 0
common_dir=$(git rev-parse --git-common-dir) || exit 0
git_dir=$(cd -- "$git_dir" >/dev/null && pwd -P) || exit 0
common_dir=$(cd -- "$common_dir" >/dev/null && pwd -P) || exit 0
[[ "$git_dir" == "$common_dir" ]] || exit 0

superproject=$(git rev-parse --show-superproject-working-tree) || exit 0
[[ -z "$superproject" ]] || exit 0

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null && pwd -P) || exit 0
"$script_dir/../skills/worktree-handoff/scripts/handoff.sh" --check >/dev/null 2>&1 || exit 0

printf '%s\n' 'このセッションは Agent Workflow Terminal の Project Root で動いている。実装を指示されたら、作業を始める前に awt-handoff:worktree-handoff Skill を使う。調査や質問には使わない。'
exit 0

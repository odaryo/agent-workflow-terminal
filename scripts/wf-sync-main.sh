#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # 実行時に解決するパスのため静的解析では追跡できない
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
使い方: wf-sync-main.sh [--dry-run]

現在のブランチへ origin/main を取り込む (merge)。
  --dry-run   実行せず、取り込まれるコミットと実行するはずの内容を表示する
  -h, --help  このヘルプを表示

rebase ではなく merge なのは、このリポジトリが squash マージ専用 (wf-pr-merge.sh が強制) で
ブランチ内の履歴が畳まれて消えるため。履歴の見た目のために rebase を選ぶ理由が無く、
rebase は push 済みブランチに force push を要求する。merge なら force 不要で結果は同じ。
EOF
}

dry_run=0

while [[ $# -gt 0 ]]; do
  case "$1" in
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

current_branch=$(current_branch_or_die)
[[ "$current_branch" != "main" ]] || die "main ブランチでは実行できません。作業ブランチへ切り替えてください"

# dirty な作業ツリーで merge すると、コンフリクト解決と未コミットの変更が混ざって
# 何が自分の変更か分からなくなる。先にコミットさせる。
if [[ -n "$(git status --porcelain)" ]]; then
  die "作業ツリーに未コミットの変更があります。先に scripts/wf-commit.sh でコミットしてください"
fi

git fetch origin main

if git merge-base --is-ancestor origin/main HEAD; then
  info "origin/main は既に取り込まれています ($current_branch)"
  exit 0
fi

incoming=$(git log --oneline HEAD..origin/main | wc -l | tr -d ' ')

if [[ "$dry_run" -eq 1 ]]; then
  info "[dry-run] 取り込まれるコミット ($incoming 件):"
  git log --oneline HEAD..origin/main >&2
  info "[dry-run] git merge --no-edit origin/main"
  exit 0
fi

if ! git merge --no-edit origin/main; then
  # コンフリクトは人 (または担当エージェント) の判断が要るので、abort せずに残す。
  # ここで abort すると解決の機会ごと失われる。
  die "merge がコンフリクトしました。衝突を解決して 'git add' したあと
    git -c core.editor=true merge --continue
  で完了させるか、やり直す場合は
    git merge --abort
  を実行してください"
fi

info "origin/main を取り込みました ($incoming 件のコミット, $current_branch)"
info "変更を push するには scripts/wf-push.sh を実行してください"

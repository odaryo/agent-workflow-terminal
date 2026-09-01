#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # 実行時に解決するパスのため静的解析では追跡できない
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
使い方: wf-push.sh [--force] [--allow-main]

現在のブランチを origin へ push する。upstream 未設定なら -u で設定する。
  --force       force-with-lease で push する (main では常にエラー)
  --allow-main  main ブランチからの push を許可する
  -h, --help    このヘルプを表示
EOF
}

force=0
allow_main=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)
      force=1
      shift
      ;;
    --allow-main)
      allow_main=1
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

if [[ "$current_branch" == "main" ]]; then
  [[ "$force" -eq 0 ]] || die "main への --force push は組み合わせ自体が禁止です"
  [[ "$allow_main" -eq 1 ]] || die "main ブランチからの push には --allow-main が必要です"
fi

has_upstream=1
git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1 || has_upstream=0

if [[ "$force" -eq 1 ]]; then
  if [[ "$has_upstream" -eq 1 ]]; then
    git push --force-with-lease origin "$current_branch"
  else
    git push -u --force-with-lease origin "$current_branch"
  fi
else
  if [[ "$has_upstream" -eq 1 ]]; then
    git push origin "$current_branch"
  else
    git push -u origin "$current_branch"
  fi
fi

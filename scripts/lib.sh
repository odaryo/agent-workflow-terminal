#!/usr/bin/env bash
# source 専用ライブラリ。実行ビットは付与しない。
set -euo pipefail

die() {
  echo "エラー: $*" >&2
  exit 1
}

info() {
  echo "$*" >&2
}

repo_root_cd() {
  local root
  root=$(git rev-parse --show-toplevel 2>/dev/null) || die "Git リポジトリの外です"
  cd "$root" || die "リポジトリルートへの移動に失敗しました: $root"
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "必須コマンドが見つかりません: $cmd"
  done
}

WF_NWO=""
# gh repo view の結果をプロセス内でキャッシュする (同一スクリプト内で複数回呼ばれるため)。
nwo() {
  if [[ -z "$WF_NWO" ]]; then
    WF_NWO=$(gh repo view --json nameWithOwner --jq .nameWithOwner) \
      || die "owner/repo の解決に失敗しました (gh repo view)"
  fi
  echo "$WF_NWO"
}

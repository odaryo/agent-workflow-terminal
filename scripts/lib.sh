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

# 値必須フラグの値欠落を bash の "unbound variable" ではなく日本語エラーにするためのガード。
# $1 = フラグ名 (エラー表示用), $2 = 呼び出し元の "$#" (シフト前の残り引数数)。
require_value() {
  [[ "$2" -ge 2 ]] || die "$1 には値が必要です"
}

# 現在ブランチ名を返す。detached HEAD の場合は日本語エラーで exit する。
current_branch_or_die() {
  local ref
  ref=$(git symbolic-ref --quiet HEAD) || die "detached HEAD 状態です。ブランチを checkout してから実行してください"
  echo "${ref#refs/heads/}"
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

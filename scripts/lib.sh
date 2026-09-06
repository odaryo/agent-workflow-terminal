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

# squash マージは PR タイトルがそのまま main のコミットログになるため、
# commit と PR の両方に同じ形式を課す (Issue #43)。
WF_CONVENTIONAL_PATTERN='^(feat|fix|docs|refactor|test|chore|ci|build|perf|style)(\([^)]+\))?!?: .+'
require_conventional_title() {
  [[ "$1" =~ $WF_CONVENTIONAL_PATTERN ]] \
    || die "$2が Conventional Commits 形式ではありません: $1"
}

WF_MERGED_HEAD_TSV=""
load_merged_pr_heads() {
  # squash マージではブランチ先端が origin/main の祖先にならないため、
  # `git branch --merged origin/main` はマージ済みブランチを検出できない
  # (squash-only 運用の本リポジトリでは削除候補が1件も出ない。Issue #45 で実測)。
  # 代わりにマージ済み PR の head を gh から取得し、ローカル/リモートの ref と突き合わせる。
  # 直近200件より古い PR のブランチは対象外だが、消しすぎ側には倒れない。
  # --base main は必須。base が main 以外の PR (stacked PR の子など) は、親が main に
  # 入らないまま閉じられると squash コミットが main から到達不能なままになるため。
  WF_MERGED_HEAD_TSV=$(gh pr list --state merged --limit 200 --base main \
    --json headRefName,headRefOid \
    --jq '.[] | .headRefName + "\t" + .headRefOid') \
    || die "マージ済み PR の取得に失敗しました (gh pr list)"
}

merged_pr_head_oids() {
  # `$1 ""` は文字列比較の強制。awk は -v 代入値が数値に見えると数値比較に切り替わり、
  # `007` と `7` のようなブランチ名が一致してしまう。
  awk -F '\t' -v name="$1" '$1 "" == name "" { print $2 }' <<<"$WF_MERGED_HEAD_TSV"
}

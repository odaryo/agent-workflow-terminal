#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # 実行時に解決するパスのため静的解析では追跡できない
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
使い方: wf-cleanup-branches.sh [--yes] [--dry-run]

マージ済み PR の head ブランチのうちリモートに残っているもの (main と現在のブランチを除く) を削除する。
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
require_cmd git gh

git fetch --prune origin

current_branch=$(git rev-parse --abbrev-ref HEAD)

# squash マージではブランチ先端が origin/main の祖先にならないため、
# `git branch -r --merged origin/main` はマージ済みブランチを検出できない
# (squash-only 運用の本リポジトリでは削除候補が1件も出ない。Issue #45 で実測)。
# 代わりにマージ済み PR の head を gh から取得し、リモートブランチと突き合わせる。
# 直近200件より古い PR のブランチは対象外だが、消しすぎ側には倒れない。
merged_head_tsv=$(gh pr list --state merged --limit 200 --json headRefName,headRefOid \
  --jq '.[] | .headRefName + "\t" + .headRefOid') \
  || die "マージ済み PR の取得に失敗しました (gh pr list)"

branches=()
# `git branch -r` ではなく for-each-ref なのは、前者が origin 以外のリモートも列挙し、
# その ref を後段の `git rev-parse refs/remotes/origin/...` が解決できず set -e で
# 中断するため (隔離リポジトリで実測)。origin 配下に限定すれば発生しない。
while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  case "$name" in
    HEAD | main | "$current_branch") continue ;;
  esac
  merged_oids=$(awk -F '\t' -v name="$name" '$1 == name { print $2 }' <<<"$merged_head_tsv")
  [[ -n "$merged_oids" ]] || continue
  tip_oid=$(git rev-parse "refs/remotes/origin/$name")
  # 同名ブランチが複数 PR で使われた場合はいずれかの head と一致すればマージ済みとみなす。
  # どの head とも一致しない = マージ後に push されたコミットがあるということで、
  # 削除すると未マージの作業を失うためスキップする。
  if grep -qxF "$tip_oid" <<<"$merged_oids"; then
    branches+=("$name")
  else
    info "警告: '$name' はマージ済み PR の head と一致しないためスキップしました (マージ後の push あり)"
  fi
done < <(git for-each-ref --format='%(refname:strip=3)' refs/remotes/origin/)

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

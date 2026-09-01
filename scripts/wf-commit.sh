#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # 実行時に解決するパスのため静的解析では追跡できない
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
使い方: wf-commit.sh -t "<title>" -b "<body>" [--allow-main]

ステージ済みの変更を Conventional Commits 形式でコミットする (git add は行わない)。
  -t, --title    コミットタイトル (例: "fix: xxx")
  -b, --body     コミット本文 (Why を書く。必須)
  --allow-main   main ブランチ上での直接コミットを許可する
                 (docs 等の1行変更のみ main 直コミット可)
  -h, --help     このヘルプを表示
EOF
}

title=""
body=""
allow_main=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t | --title)
      require_value "-t/--title" "$#"
      title="$2"
      shift 2
      ;;
    -b | --body)
      require_value "-b/--body" "$#"
      body="$2"
      shift 2
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

[[ -n "$title" ]] || die "タイトル (-t) を指定してください"
[[ -n "$body" ]] || die "本文 (-b) を指定してください (Why を必ず書く)"

if git diff --cached --quiet; then
  die "ステージ済みの変更がありません (git add で対象ファイルを追加してください)"
fi

require_conventional_title "$title" "タイトル"

current_branch=$(current_branch_or_die)
if [[ "$current_branch" == "main" && "$allow_main" -ne 1 ]]; then
  die "main ブランチへの直接コミットは禁止です (docs 等の1行変更のみ --allow-main で許可)"
fi

git commit -m "$title" -m "$body"

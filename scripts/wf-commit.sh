#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # 実行時に解決するパスのため静的解析では追跡できない
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
使い方: wf-commit.sh -t "<title>" -b "<body>" [--amend] [--allow-main]

ステージ済みの変更を Conventional Commits 形式でコミットする (git add は行わない)。
  -t, --title    コミットタイトル (例: "fix: xxx")
  -b, --body     コミット本文 (Why を書く。必須)
  --amend        HEAD のコミットを書き換える。ステージ済みの変更が無くても
                 メッセージだけを直せる。ステージ済みの変更があれば直前のコミットへ
                 取り込まれる。push 済みのコミットには使えない
  --allow-main   main ブランチ上での直接コミットを許可する
                 (docs 等の1行変更のみ main 直コミット可)
  -h, --help     このヘルプを表示
EOF
}

title=""
body=""
allow_main=0
amend=0

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
    --amend)
      amend=1
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

[[ -n "$title" ]] || die "タイトル (-t) を指定してください"
[[ -n "$body" ]] || die "本文 (-b) を指定してください (Why を必ず書く)"

if [[ "$amend" -eq 1 ]]; then
  # push 済みのコミットを書き換えると、他の clone や PR の diff と齟齬が出る。
  # remote へ到達済みかで判定する (upstream 未設定でも効かせるため -r で全 remote を見る)。
  git rev-parse --verify --quiet HEAD >/dev/null || die "書き換える HEAD がありません"
  # remote-tracking ref は最後の fetch/push 時点の状態でしかない。判定前に更新する。
  # offline 等で更新できない場合はローカルの ref のまま判定を続ける (fetch の失敗自体は理由にしない)。
  git fetch --quiet origin 2>/dev/null || true
  # 判定そのものが失敗したときに「push されていない」と誤読しないよう、空文字と失敗を区別する。
  pushed_refs=$(git branch -r --contains HEAD) \
    || die "push 済みかどうかを判定できませんでした (git branch -r --contains)"
  [[ -z "$pushed_refs" ]] || die "HEAD は push 済みです。--amend では書き換えられません"
elif git diff --cached --quiet; then
  die "ステージ済みの変更がありません (git add で対象ファイルを追加してください)"
fi

require_conventional_title "$title" "タイトル"

current_branch=$(current_branch_or_die)
if [[ "$current_branch" == "main" && "$allow_main" -ne 1 ]]; then
  die "main ブランチへの直接コミットは禁止です (docs 等の1行変更のみ --allow-main で許可)"
fi

if [[ "$amend" -eq 1 ]]; then
  git commit --amend -m "$title" -m "$body"
else
  git commit -m "$title" -m "$body"
fi

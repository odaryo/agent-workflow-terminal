#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # 実行時に解決するパスのため静的解析では追跡できない
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
使い方: scripts/install-user-app.sh [--ref <commit-ish>] [--dest <dir>]

日常利用のアプリを、開発版と独立したバンドルとしてインストールする。
  --ref <commit-ish>  ビルドする commit (既定: main)
  --dest <dir>        インストール先ディレクトリ (既定: ~/Applications)
  -h, --help          このヘルプを表示
EOF
}

ref="main"
dest="$HOME/Applications"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref | --dest)
      require_value "$1" "$#"
      [[ -n "$2" && "$2" != -* ]] || die "$1 の値を指定してください: $2"
      if [[ "$1" == "--ref" ]]; then
        ref="$2"
      else
        dest="$2"
      fi
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "不明な引数です: $1" ;;
  esac
done

repo_root_cd
require_cmd git pgrep mktemp cp mv rm mkdir plutil codesign
source_commit=$(git rev-parse --verify "${ref}^{commit}") \
  || die "commit を解決できません: $ref"

ensure_user_app_stopped() {
  local status
  if pgrep -x AgentWorkflowTerminalUser >/dev/null; then
    die "日常利用のアプリが動いています。終了してから再実行してください"
  else
    status=$?
    [[ "$status" -eq 1 ]] || die "日常利用のアプリの起動状態を確認できません"
  fi
}

ensure_user_app_stopped

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/awt-user-app.XXXXXX")
worktree="$tmp_dir/src"
stage_dir=""

cleanup() {
  local status=$?
  trap - EXIT
  if [[ -e "$worktree" ]]; then
    if ! git worktree remove --force "$worktree"; then
      info "一時 worktree の削除に失敗しました: $worktree"
      status=1
    fi
  fi
  if [[ -n "$stage_dir" ]]; then
    rm -rf -- "$stage_dir" || status=1
  fi
  rm -rf -- "$tmp_dir" || status=1
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

git worktree add --detach "$worktree" "$source_commit"
(
  cd "$worktree"
  scripts/fetch-ghostty.sh
  scripts/build-app.sh release
)

mkdir -p -- "$dest"
dest=$(cd -- "$dest" && pwd -P)
app_name="AgentWorkflowTerminal (User).app"
app="$dest/$app_name"
stage_dir=$(mktemp -d "$dest/.AgentWorkflowTerminal (User).app.XXXXXX")
staged_app="$stage_dir/$app_name"
cp -R "$worktree/App/build/AgentWorkflowTerminal.app" "$staged_app"

mv "$staged_app/Contents/MacOS/AgentWorkflowTerminalApp" \
  "$staged_app/Contents/MacOS/AgentWorkflowTerminalUser"
plist="$staged_app/Contents/Info.plist"
plutil -replace CFBundleExecutable -string AgentWorkflowTerminalUser "$plist"
plutil -replace CFBundleIdentifier -string dev.local.agentworkflowterminal.user "$plist"
plutil -replace CFBundleName -string 'AgentWorkflowTerminal (User)' "$plist"
plutil -replace AWTSourceCommit -string "$source_commit" "$plist"
printf '%s\n' "$source_commit" >"$staged_app/Contents/Resources/source-commit.txt"
codesign --force --sign - "$staged_app"

ensure_user_app_stopped
rm -rf -- "$app"
mv "$staged_app" "$app"

info "インストール先: $app"
info "SHA: $source_commit"
printf -v read_command 'plutil -extract AWTSourceCommit raw %q' "$app/Contents/Info.plist"
info "読み出し方: $read_command"

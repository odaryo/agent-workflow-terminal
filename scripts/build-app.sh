#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<'USAGE'
使い方: scripts/build-app.sh [debug|release]
USAGE
}

if [[ "${1:-}" = "-h" || "${1:-}" = "--help" ]]; then
  usage
  exit 0
fi
[[ "$#" -le 1 ]] || die "引数が多すぎます"
CONFIGURATION="${1:-debug}"
[[ "${CONFIGURATION}" = "debug" || "${CONFIGURATION}" = "release" ]] \
  || die "build configuration は debug または release を指定してください"

repo_root_cd
ROOT_DIR="$PWD"
PACKAGE_DIR="${ROOT_DIR}/App"
SHARE_DIR="${PACKAGE_DIR}/vendor/ghostty/zig-out/share"
XCFRAMEWORK="${PACKAGE_DIR}/vendor/ghostty/macos/GhosttyKit.xcframework"
APP="${PACKAGE_DIR}/build/AgentWorkflowTerminal.app"
EXECUTABLE="AgentWorkflowTerminalApp"

require_cmd swift codesign plutil
[ -d "${XCFRAMEWORK}" ] || die "先に scripts/build-ghostty.sh を実行してください"
[ -d "${SHARE_DIR}/ghostty" ] || die "ghostty resources がありません"
[ -d "${SHARE_DIR}/terminfo" ] || die "terminfo resources がありません"

info "swift build -c ${CONFIGURATION}"
# --show-bin-path はビルドせずパスを表示するだけ (Swift 6.3.2 で実測)。
# 1回にまとめると古いバイナリを黙ってバンドルへ配るため、ビルドとパス取得を分ける。
(cd "${PACKAGE_DIR}" && swift build -c "${CONFIGURATION}")
BIN_DIR="$(cd "${PACKAGE_DIR}" && swift build -c "${CONFIGURATION}" --show-bin-path)"
BIN="${BIN_DIR}/${EXECUTABLE}"
[ -f "${BIN}" ] || die "実行ファイルがありません: ${BIN}"

info "アプリバンドルを組み立てます: ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN}" "${APP}/Contents/MacOS/${EXECUTABLE}"

# 製品名と配布方法が未確定なため、bundle identifier はローカル用の暫定値。
PLIST="${APP}/Contents/Info.plist"
plutil -create xml1 "${PLIST}"
plutil -insert CFBundleExecutable -string "${EXECUTABLE}" "${PLIST}"
plutil -insert CFBundleIdentifier -string "dev.local.agentworkflowterminal" "${PLIST}"
plutil -insert CFBundleName -string "AgentWorkflowTerminal" "${PLIST}"
plutil -insert CFBundlePackageType -string "APPL" "${PLIST}"
plutil -insert CFBundleShortVersionString -string "0.0.1" "${PLIST}"
plutil -insert CFBundleVersion -string "1" "${PLIST}"
plutil -insert LSMinimumSystemVersion -string "14.0" "${PLIST}"
plutil -insert NSHighResolutionCapable -bool true "${PLIST}"
plutil -insert NSPrincipalClass -string "NSApplication" "${PLIST}"

cp -R "${SHARE_DIR}/ghostty" "${APP}/Contents/Resources/ghostty"
cp -R "${SHARE_DIR}/terminfo" "${APP}/Contents/Resources/terminfo"

codesign --force --sign - "${APP}"
info "完了: ${APP}"

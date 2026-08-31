#!/usr/bin/env bash
#
# Gate 1 PoC (M1) — TerminalSpike.app をビルドする
#
#   Spikes/gate1/scripts/build-app.sh [debug|release]
#
# 事前に scripts/build-ghostty.sh を通しておくこと。
#
# なぜ .app バンドルを作るのか:
#   - SwiftPM の executable はただの実行ファイルで、バンドル ID も
#     Info.plist も無い。そのままだと NSApplication の activation や
#     メニューバーの扱いが不安定で、ターミナル品質の検証にならない。
#   - libghostty は `<GHOSTTY_RESOURCES_DIR>/../terminfo` を子プロセスの
#     TERMINFO に渡す (src/termio/Exec.zig)。そのため
#       Contents/Resources/ghostty/    ← GHOSTTY_RESOURCES_DIR
#       Contents/Resources/terminfo/
#     というレイアウトを作る必要がある。本家 Ghostty.app と同じ構造。
#
set -euo pipefail

CONFIG="${1:-debug}"

SPIKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG_DIR="${SPIKE_DIR}/TerminalSpike"
SHARE_DIR="${SPIKE_DIR}/vendor/ghostty/zig-out/share"
OUT_DIR="${SPIKE_DIR}/build"
APP="${OUT_DIR}/TerminalSpike.app"

log() { printf '\033[1;34m[build-app]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[build-app] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ -d "${SHARE_DIR}/ghostty" ] || die "先に scripts/build-ghostty.sh を実行すること"

log "swift build -c ${CONFIG}"
(cd "${PKG_DIR}" && swift build -c "${CONFIG}")
BIN="$(cd "${PKG_DIR}" && swift build -c "${CONFIG}" --show-bin-path)/TerminalSpike"
[ -f "${BIN}" ] || die "実行ファイルが無い: ${BIN}"

log "assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN}" "${APP}/Contents/MacOS/TerminalSpike"

cat > "${APP}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>TerminalSpike</string>
  <key>CFBundleIdentifier</key><string>dev.local.gate1.terminalspike</string>
  <key>CFBundleName</key><string>TerminalSpike</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# libghostty のリソース (terminfo / shell-integration / themes)
cp -R "${SHARE_DIR}/ghostty"  "${APP}/Contents/Resources/ghostty"
cp -R "${SHARE_DIR}/terminfo" "${APP}/Contents/Resources/terminfo"

# ad-hoc 署名。未署名だと Metal / 入力周りで挙動が変わることがある
codesign --force --sign - "${APP}" >/dev/null 2>&1 \
  || log "warning: codesign に失敗した (未署名のまま続行)"

log "OK: ${APP}"
log "  起動: open '${APP}'   /   '${APP}/Contents/MacOS/TerminalSpike'"
log "  コマンド差し替え: TERMINAL_SPIKE_COMMAND='tmux -L gate1-spike new-session -A -s gate1-spike' (M2)"

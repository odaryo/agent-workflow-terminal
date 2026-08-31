#!/usr/bin/env bash
#
# Gate 1 PoC (M0) — GhosttyKit.xcframework をビルドする
#
#   Spikes/gate1/scripts/build-ghostty.sh
#
# 前提:
#   - Xcode がインストール済みで `xcode-select -p` が Xcode を指していること
#   - Metal Toolchain が導入済みであること
#       xcodebuild -downloadComponent MetalToolchain
#     (未導入だと `metal` が無く shaders.metal のコンパイルで失敗する。約 690MB)
#   - zig 0.15.x (ghostty v1.3.1 の minimum_zig_version = 0.15.2)
#       brew install zig@0.15     # keg-only。PATH はこのスクリプトが通す
#   - LLVM の llvm-libtool-darwin (下記 WORKAROUND を参照)
#       brew install llvm@20      # zig@0.15 の依存として自動で入る
#
# ピン留め方針 (PLAN.md §4.7 案A):
#   ghostty は v1.3.1 に固定する。iOS スライスが残る最後のタグであり、
#   Gate 2 の選択肢を閉じないため。upstream main は使わない。
#
set -euo pipefail

GHOSTTY_REF="v1.3.1"
ZIG_PREFIX="/opt/homebrew/opt/zig@0.15"
LLVM_PREFIX="/opt/homebrew/opt/llvm@20"

SPIKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="${SPIKE_DIR}/vendor"
GHOSTTY_DIR="${VENDOR_DIR}/ghostty"
SHIM_DIR="${SPIKE_DIR}/.build-shim"

log() { printf '\033[1;34m[build-ghostty]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[build-ghostty] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 前提チェック

[ -x "${ZIG_PREFIX}/bin/zig" ] || die "zig 0.15 が見つからない: brew install zig@0.15"
xcrun -sdk macosx metal --version >/dev/null 2>&1 \
  || die "Metal Toolchain が無い: xcodebuild -downloadComponent MetalToolchain"

# ------------------------------------------------------------------ clone/pin

if [ ! -d "${GHOSTTY_DIR}/.git" ]; then
  log "cloning ghostty ${GHOSTTY_REF} -> ${GHOSTTY_DIR}"
  mkdir -p "${VENDOR_DIR}"
  git clone --depth 1 --branch "${GHOSTTY_REF}" \
    https://github.com/ghostty-org/ghostty "${GHOSTTY_DIR}"
else
  log "ghostty already cloned ($(git -C "${GHOSTTY_DIR}" describe --tags --always))"
fi

# ------------------------------------------------------- WORKAROUND: libtool
#
# ghostty の build.zig は `libtool -static -o libghostty-fat.a <入力.a ...>` で
# 依存ライブラリを 1 本の static library にまとめる (src/build/LibtoolStep.zig)。
#
# ところが Xcode 26.5 (macOS 26.5) 同梱の /usr/bin/libtool は、zig が生成した
# アーカイブを入力にすると **一部のメンバ .o を警告だけ出して黙って落とす**。
#   libtool: warning: 64-bit mach-o member 'libghostty_zcu.o' not 8-byte aligned
# 結果、出力アーカイブから libghostty_zcu.o / vt.o / wuffs-v0.4.o / freetype /
# glslang / oniguruma / gettext / imgui 等のオブジェクトが欠落し、リンク時に
# `Undefined symbols: _ghostty_init, _FT_*, _glslang_*, ...` になる。
# (xcframework 自体は生成されるため、症状はリンク時まで出ない)
#
# LLVM の llvm-libtool-darwin は同じ入力を正しく処理するので、PATH の先頭に
# `libtool` という名前でシムを置いて差し替える。ghostty 側は改変しない。
#
# 本採用時の申し送り: この差異は upstream ghostty v1.3.1 と Xcode 26 の
# 組み合わせ固有の問題。追随方針を決めるまでこのシムが必要。

[ -x "${LLVM_PREFIX}/bin/llvm-libtool-darwin" ] \
  || die "llvm-libtool-darwin が無い: brew install llvm@20"

mkdir -p "${SHIM_DIR}"
ln -sf "${LLVM_PREFIX}/bin/llvm-libtool-darwin" "${SHIM_DIR}/libtool"

export PATH="${SHIM_DIR}:${ZIG_PREFIX}/bin:${PATH}"

log "zig      : $(zig version)"
log "libtool  : $(readlink "${SHIM_DIR}/libtool")"
log "xcode    : $(xcode-select -p)"

# ----------------------------------------------------------------------- build

cd "${GHOSTTY_DIR}"

if [ "${CLEAN:-0}" = "1" ]; then
  log "CLEAN=1 -> removing .zig-cache and previous xcframework"
  rm -rf .zig-cache macos/GhosttyKit.xcframework
fi

log "zig build (ReleaseFast, native/arm64 only)"
time zig build \
  -Demit-xcframework=true \
  -Demit-macos-app=false \
  -Dxcframework-target=native \
  -Doptimize=ReleaseFast

# ----------------------------------------------------------------------- 検証

XCFW="${GHOSTTY_DIR}/macos/GhosttyKit.xcframework"
LIB="${XCFW}/macos-arm64/libghostty-fat.a"

[ -d "${XCFW}" ] || die "xcframework が生成されていない: ${XCFW}"
[ -f "${LIB}" ]  || die "static library が無い: ${LIB}"

# 上記 libtool 問題の再発検知。ここで落ちたら PATH のシムが効いていない。
# (grep -q は SIGPIPE で nm を落とし pipefail に引っかかるので使わない)
symbol_count="$(nm -g "${LIB}" 2>/dev/null | grep -c '_ghostty_init' || true)"
if [ "${symbol_count}" -eq 0 ]; then
  die "libghostty-fat.a に _ghostty_init が無い。libtool のメンバ欠落が再発している"
fi

# GHOSTTY_RESOURCES_DIR 用のリソース (terminfo / shell-integration)
for d in zig-out/share/ghostty zig-out/share/terminfo/78/xterm-ghostty; do
  [ -e "${GHOSTTY_DIR}/${d}" ] || die "リソースが無い: ${d}"
done

log "OK"
log "  xcframework : ${XCFW}"
log "               (注: PLAN.md §4.2 は zig-out/macos/ と書いているが、"
log "                v1.3.1 の実際の出力先はリポジトリ直下の macos/ である)"
log "  headers     : ${XCFW}/macos-arm64/Headers/ghostty.h"
log "  resources   : ${GHOSTTY_DIR}/zig-out/share/ghostty  (GHOSTTY_RESOURCES_DIR)"
log "  terminfo    : ${GHOSTTY_DIR}/zig-out/share/terminfo"

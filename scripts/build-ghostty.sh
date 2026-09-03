#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<'USAGE'
使い方: scripts/build-ghostty.sh

CLEAN=1 を指定するとキャッシュと前回の xcframework を削除して再ビルドします。
USAGE
}

if [[ "${1:-}" = "-h" || "${1:-}" = "--help" ]]; then
  usage
  exit 0
fi
[[ "$#" -eq 0 ]] || { usage >&2; die "引数は指定できません"; }

GHOSTTY_REF="v1.3.1"
ZIG_PREFIX="/opt/homebrew/opt/zig@0.15"
LLVM_PREFIX="/opt/homebrew/opt/llvm@20"

repo_root_cd
ROOT_DIR="$PWD"
VENDOR_DIR="${ROOT_DIR}/App/vendor"
GHOSTTY_DIR="${VENDOR_DIR}/ghostty"
SHIM_DIR="${ROOT_DIR}/App/.build-shim"

[ -x "${ZIG_PREFIX}/bin/zig" ] \
  || die "zig 0.15 が見つかりません: brew install zig@0.15"
[ -x "${LLVM_PREFIX}/bin/llvm-libtool-darwin" ] \
  || die "llvm-libtool-darwin が見つかりません: brew install llvm@20"
command -v xcrun >/dev/null 2>&1 || die "xcrun が見つかりません。Xcode を導入してください"
xcrun -sdk macosx metal --version >/dev/null 2>&1 \
  || die "Metal Toolchain がありません: xcodebuild -downloadComponent MetalToolchain"

if [ ! -d "${GHOSTTY_DIR}/.git" ]; then
  info "ghostty ${GHOSTTY_REF} を取得します"
  mkdir -p "${VENDOR_DIR}"
  git clone --depth 1 --branch "${GHOSTTY_REF}" \
    https://github.com/ghostty-org/ghostty "${GHOSTTY_DIR}"
fi

current_ref="$(git -C "${GHOSTTY_DIR}" describe --tags --exact-match 2>/dev/null || true)"
[ "${current_ref}" = "${GHOSTTY_REF}" ] \
  || die "ghostty は ${GHOSTTY_REF} である必要があります (現在: ${current_ref:-不明})"

mkdir -p "${SHIM_DIR}"
ln -sf "${LLVM_PREFIX}/bin/llvm-libtool-darwin" "${SHIM_DIR}/libtool"
export PATH="${SHIM_DIR}:${ZIG_PREFIX}/bin:${PATH}"
[ "$(command -v libtool)" = "${SHIM_DIR}/libtool" ] \
  || die "llvm-libtool-darwin のシムを PATH 先頭に設定できませんでした"

if [ "${CLEAN:-0}" = "1" ]; then
  info "CLEAN=1: キャッシュと前回の xcframework を削除します"
  rm -rf "${GHOSTTY_DIR}/.zig-cache" \
    "${GHOSTTY_DIR}/macos/GhosttyKit.xcframework"
fi

info "GhosttyKit.xcframework をビルドします"
(
  cd "${GHOSTTY_DIR}"
  zig build \
    -Demit-xcframework=true \
    -Demit-macos-app=false \
    -Dxcframework-target=native \
    -Doptimize=ReleaseFast
)

XCFRAMEWORK="${GHOSTTY_DIR}/macos/GhosttyKit.xcframework"
LIBRARY="${XCFRAMEWORK}/macos-arm64/libghostty-fat.a"
[ -d "${XCFRAMEWORK}" ] || die "xcframework が生成されていません: ${XCFRAMEWORK}"
[ -f "${LIBRARY}" ] || die "static library がありません: ${LIBRARY}"

symbol_count="$(nm -g "${LIBRARY}" 2>/dev/null | grep -c '_ghostty_init' || true)"
[ "${symbol_count}" -gt 0 ] \
  || die "_ghostty_init がありません。libtool シムが機能していない可能性があります"

for directory in zig-out/share/ghostty zig-out/share/terminfo; do
  [ -d "${GHOSTTY_DIR}/${directory}" ] \
    || die "必要なリソースがありません: ${GHOSTTY_DIR}/${directory}"
done

info "完了: ${XCFRAMEWORK}"

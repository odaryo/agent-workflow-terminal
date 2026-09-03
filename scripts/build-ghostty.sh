#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 # 実行時に解決するパスのため静的解析では追跡できない
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
[[ "$#" -eq 0 ]] || die "引数は指定できません"

ZIG_PREFIX="/opt/homebrew/opt/zig@0.15"
LLVM_PREFIX="/opt/homebrew/opt/llvm@20"

repo_root_cd
ROOT_DIR="$PWD"
[[ -f "${ROOT_DIR}/App/ghostty-ref" ]] || die "App/ghostty-ref がありません"
GHOSTTY_REF="$(<"${ROOT_DIR}/App/ghostty-ref")"
[ -n "${GHOSTTY_REF}" ] || die "App/ghostty-ref が空です"
VENDOR_DIR="${ROOT_DIR}/App/vendor"
GHOSTTY_DIR="${VENDOR_DIR}/ghostty"
SHIM_DIR="${ROOT_DIR}/App/.build-shim"

if [ -e "${GHOSTTY_DIR}" ] && [ ! -d "${GHOSTTY_DIR}/.git" ]; then
  die "${GHOSTTY_DIR} は fetch 済みの成果物です。自前ビルドするには App/vendor/ghostty を削除してから再実行してください"
fi

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
if [ "${current_ref}" != "${GHOSTTY_REF}" ]; then
  info "ghostty を ${GHOSTTY_REF} へ更新します (現在: ${current_ref:-不明})"
  git -C "${GHOSTTY_DIR}" fetch --depth 1 origin tag "${GHOSTTY_REF}" \
    || die "ghostty ${GHOSTTY_REF} の取得に失敗しました。App/vendor/ghostty を削除して再実行してください"
  git -C "${GHOSTTY_DIR}" checkout --detach "${GHOSTTY_REF}" \
    || die "ghostty ${GHOSTTY_REF} の checkout に失敗しました。App/vendor/ghostty を削除して再実行してください"
  current_ref="$(git -C "${GHOSTTY_DIR}" describe --tags --exact-match 2>/dev/null || true)"
fi
[ "${current_ref}" = "${GHOSTTY_REF}" ] \
  || die "ghostty を ${GHOSTTY_REF} へ更新できませんでした (現在: ${current_ref:-不明})。App/vendor/ghostty を削除して再実行してください"

rm -f "${GHOSTTY_DIR}/GHOSTTY-BUILD-STAMP.txt"

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

commit="$(git -C "${GHOSTTY_DIR}" rev-parse HEAD)" \
  || die "ghostty の commit SHA を取得できませんでした"
{
  printf 'ref: %s\n' "${GHOSTTY_REF}"
  printf 'commit: %s\n' "${commit}"
  printf 'built_at: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'host: %s\n' "$(uname -sm)"
} >"${GHOSTTY_DIR}/GHOSTTY-BUILD-STAMP.txt"

info "完了: ${XCFRAMEWORK}"

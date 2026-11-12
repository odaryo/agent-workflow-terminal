#!/usr/bin/env bash
set -euo pipefail

XCODEGEN_VERSION="2.46.0"
XCODEGEN_SHA256="4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

[[ $# -eq 1 && -n "${1:-}" ]] \
  || die "使い方: scripts/fetch-xcodegen.sh <出力ディレクトリ>"
require_cmd curl shasum unzip mktemp

mkdir -p "$1"
OUTPUT_DIR="$(cd "$1" && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/awt-xcodegen.XXXXXX")"
# bash 3.2 の展開エラーが EXIT trap によって成功扱いになるのを防ぐ (規約 §7)。
__awt_finished=0
__awt_on_exit() {
  local rc=$?
  rm -rf "$TMP_DIR"
  [[ $__awt_finished -eq 1 || $rc -ne 0 ]] || rc=1
  exit "$rc"
}
trap __awt_on_exit EXIT

curl --fail --location --silent --show-error \
  "https://github.com/yonaskolb/XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip" \
  --output "$TMP_DIR/xcodegen.zip"
(
  cd "$TMP_DIR"
  printf '%s  xcodegen.zip\n' "$XCODEGEN_SHA256" | shasum -a 256 -c -
) >&2 || die "XcodeGen の sha256 が一致しません"
unzip -q -o "$TMP_DIR/xcodegen.zip" -d "$OUTPUT_DIR" >&2
[[ -x "$OUTPUT_DIR/xcodegen/bin/xcodegen" ]] \
  || die "展開した XcodeGen の実行ファイルがありません"
printf '%s\n' "$OUTPUT_DIR/xcodegen/bin/xcodegen"
__awt_finished=1

#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<'USAGE'
使い方: scripts/make-app-icon.sh

App/Resources/AppIcon/AppIcon.svg から App/Resources/AppIcon/AppIcon.icns を作り直す。
生成した .icns はコミットする (scripts/build-app.sh はそれを写すだけで、ここは呼ばない)。
rsvg-convert が必要 (brew install librsvg)。
USAGE
}

if [[ "${1:-}" = "-h" || "${1:-}" = "--help" ]]; then
  usage
  exit 0
fi
[[ "$#" -eq 0 ]] || die "引数は指定できません"

repo_root_cd
ICON_DIR="${PWD}/App/Resources/AppIcon"
SVG="${ICON_DIR}/AppIcon.svg"
ICNS="${ICON_DIR}/AppIcon.icns"

require_cmd rsvg-convert iconutil
[ -f "${SVG}" ] || die "原本がありません: ${SVG}"

work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT
# iconutil は拡張子 .iconset のディレクトリしか受け付けない。
ICONSET="${work_dir}/AppIcon.iconset"
mkdir "${ICONSET}"

for size in 16 32 128 256 512; do
  rsvg-convert -w "${size}" -h "${size}" -o "${ICONSET}/icon_${size}x${size}.png" "${SVG}"
  rsvg-convert -w "$((size * 2))" -h "$((size * 2))" -o "${ICONSET}/icon_${size}x${size}@2x.png" "${SVG}"
done

iconutil -c icns -o "${ICNS}" "${ICONSET}"
info "完了: ${ICNS}"

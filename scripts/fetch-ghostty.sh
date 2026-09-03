#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # 実行時に解決するパスのため静的解析では追跡できない
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
使い方: fetch-ghostty.sh

CI 用の事前ビルド済み GhosttyKit を Release アセットから取得する。
  -h, --help  このヘルプを表示
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
[[ $# -eq 0 ]] || die "引数は指定できません"

repo_root_cd
require_cmd gh shasum tar uname mktemp

[[ "$(uname -m)" == "arm64" ]] \
  || die "このアセットは macos-arm64 専用です (現在のアーキテクチャ: $(uname -m))"

root_dir="$PWD"
ghostty_dir="$root_dir/App/vendor/ghostty"
ghostty_ref="$(<"$root_dir/App/ghostty-ref")"
[[ -n "$ghostty_ref" ]] || die "App/ghostty-ref が空です"
[[ ! -d "$ghostty_dir/.git" ]] \
  || die "自前ビルド済みのため fetch は不要です。強制するなら App/vendor/ghostty を削除してから再実行してください"

asset="GhosttyKit-${ghostty_ref}-macos-arm64.tar.gz"
checksum_asset="${asset}.sha256"
release_tag="ghostty-kit-${ghostty_ref}"
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/ghostty-fetch.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

if ! gh release download "$release_tag" \
  --pattern "$asset" \
  --pattern "$checksum_asset" \
  --dir "$tmp_dir"; then
  die "App/ghostty-ref の ref (${ghostty_ref}) に対応する Release アセットがありません。scripts/build-ghostty.sh && scripts/wf-ghostty-publish.sh で publish してください"
fi

(
  cd "$tmp_dir"
  shasum -a 256 -c "$checksum_asset"
) || die "GhosttyKit Release アセットの sha256 が一致しません"

extract_dir="$tmp_dir/extracted"
mkdir -p "$extract_dir"
tar -xzf "$tmp_dir/$asset" -C "$extract_dir"
[[ -d "$extract_dir/macos/GhosttyKit.xcframework" ]] \
  || die "展開したアセットに macos/GhosttyKit.xcframework がありません"
[[ -d "$extract_dir/zig-out/share/ghostty" ]] \
  || die "展開したアセットに zig-out/share/ghostty がありません"
[[ -d "$extract_dir/zig-out/share/terminfo" ]] \
  || die "展開したアセットに zig-out/share/terminfo がありません"
[[ -f "$extract_dir/GHOSTTY-MANIFEST.txt" ]] \
  || die "展開したアセットに GHOSTTY-MANIFEST.txt がありません"

if [[ -e "$ghostty_dir" ]]; then
  rm -rf "$ghostty_dir"
fi
mkdir -p "$(dirname "$ghostty_dir")"
mv "$extract_dir" "$ghostty_dir"

info "取得した GhosttyKit の manifest:"
while IFS= read -r line; do
  info "$line"
done <"$ghostty_dir/GHOSTTY-MANIFEST.txt"

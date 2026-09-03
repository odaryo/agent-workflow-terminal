#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # 実行時に解決するパスのため静的解析では追跡できない
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
使い方: wf-ghostty-publish.sh [--dry-run]

ローカルでビルド済みの GhosttyKit を Release アセットとして publish する。
  --dry-run   publish せず、成果物と実行予定の gh コマンドを表示する
  -h, --help  このヘルプを表示
EOF
}

dry_run=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      dry_run=1
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
require_cmd git tar shasum uname mktemp du gh

root_dir="$PWD"
ghostty_dir="$root_dir/App/vendor/ghostty"
ghostty_ref="$(<"$root_dir/App/ghostty-ref")"
[[ -n "$ghostty_ref" ]] || die "App/ghostty-ref が空です"

[[ -d "$ghostty_dir/macos/GhosttyKit.xcframework" ]] \
  || die "GhosttyKit.xcframework がありません: $ghostty_dir/macos/GhosttyKit.xcframework"
[[ -d "$ghostty_dir/zig-out/share/ghostty" ]] \
  || die "ghostty リソースがありません: $ghostty_dir/zig-out/share/ghostty"
[[ -d "$ghostty_dir/zig-out/share/terminfo" ]] \
  || die "terminfo リソースがありません: $ghostty_dir/zig-out/share/terminfo"
[[ -f "$ghostty_dir/LICENSE" ]] || die "LICENSE がありません: $ghostty_dir/LICENSE"
[[ -d "$ghostty_dir/.git" ]] || die "$ghostty_dir は git clone ではありません"

current_ref=$(git -C "$ghostty_dir" describe --tags --exact-match 2>/dev/null) \
  || die "ghostty clone はタグを exact match していません"
[[ "$current_ref" == "$ghostty_ref" ]] \
  || die "ghostty clone の ref が App/ghostty-ref と一致しません (期待: $ghostty_ref, 現在: $current_ref)"
commit=$(git -C "$ghostty_dir" rev-parse HEAD) || die "ghostty の commit SHA を取得できませんでした"

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/ghostty-publish.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT
stage_dir="$tmp_dir/stage"
mkdir -p "$stage_dir/macos" "$stage_dir/zig-out/share"
cp -R "$ghostty_dir/macos/GhosttyKit.xcframework" "$stage_dir/macos/"
cp -R "$ghostty_dir/zig-out/share/ghostty" "$stage_dir/zig-out/share/"
cp -R "$ghostty_dir/zig-out/share/terminfo" "$stage_dir/zig-out/share/"
cp "$ghostty_dir/LICENSE" "$stage_dir/LICENSE"

built_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
host=$(uname -sm)
{
  printf 'ref: %s\n' "$ghostty_ref"
  printf 'commit: %s\n' "$commit"
  printf 'built_at: %s\n' "$built_at"
  printf 'host: %s\n' "$host"
  printf 'license: MIT (ghostty-org/ghostty)\n'
} >"$stage_dir/GHOSTTY-MANIFEST.txt"

asset="GhosttyKit-${ghostty_ref}-macos-arm64.tar.gz"
checksum_asset="${asset}.sha256"
tarball="$tmp_dir/$asset"
(
  cd "$stage_dir"
  tar -czf "$tarball" \
    macos/GhosttyKit.xcframework \
    zig-out/share/ghostty \
    zig-out/share/terminfo \
    LICENSE \
    GHOSTTY-MANIFEST.txt
)
(
  cd "$tmp_dir"
  shasum -a 256 "$asset" >"$checksum_asset"
)

size=$(du -h "$tarball" | awk '{print $1}')
sha256=$(awk '{print $1}' "$tmp_dir/$checksum_asset")
info "成果物: $asset ($size)"
info "sha256: $sha256"

release_tag="ghostty-kit-${ghostty_ref}"
release_title="GhosttyKit ${ghostty_ref} (macOS arm64)"
notes="Ghostty ref: ${ghostty_ref}
Commit: ${commit}
License: MIT — https://github.com/ghostty-org/ghostty

CI で App/ をコンパイルするための事前ビルド済み成果物です。"

if [[ "$dry_run" -eq 1 ]]; then
  info "[dry-run] gh release view $release_tag"
  info "[dry-run] 未作成の場合: gh release create $release_tag --title \"$release_title\" --notes <notes>"
  info "[dry-run] gh release upload $release_tag $asset $checksum_asset --clobber"
  exit 0
fi

if ! gh release view "$release_tag" >/dev/null 2>&1; then
  gh release create "$release_tag" --title "$release_title" --notes "$notes"
fi
gh release upload "$release_tag" "$tarball" "$tmp_dir/$checksum_asset" --clobber
info "publish しました: $release_tag"

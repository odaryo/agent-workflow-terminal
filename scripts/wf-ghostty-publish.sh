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
require_cmd tar shasum mktemp du gh

root_dir="$PWD"
ghostty_dir="$root_dir/App/vendor/ghostty"
[[ -f "$root_dir/App/ghostty-ref" ]] || die "App/ghostty-ref がありません"
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

build_stamp="$ghostty_dir/GHOSTTY-BUILD-STAMP.txt"
[[ -f "$build_stamp" ]] \
  || die "ビルドスタンプがありません。scripts/build-ghostty.sh を実行し直してください"
built_ref=$(sed -n 's/^ref: //p' "$build_stamp")
commit=$(sed -n 's/^commit: //p' "$build_stamp")
built_at=$(sed -n 's/^built_at: //p' "$build_stamp")
host=$(sed -n 's/^host: //p' "$build_stamp")
[[ -n "$built_ref" && -n "$commit" && -n "$built_at" && -n "$host" ]] \
  || die "ビルドスタンプが不完全です。scripts/build-ghostty.sh を実行し直してください"
[[ "$built_ref" == "$ghostty_ref" ]] \
  || die "xcframework は ref $built_ref からビルドされています。scripts/build-ghostty.sh を実行し直してください"

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/ghostty-publish.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT
stage_dir="$tmp_dir/stage"
mkdir -p "$stage_dir/macos" "$stage_dir/zig-out/share"
cp -R "$ghostty_dir/macos/GhosttyKit.xcframework" "$stage_dir/macos/"
cp -R "$ghostty_dir/zig-out/share/ghostty" "$stage_dir/zig-out/share/"
cp -R "$ghostty_dir/zig-out/share/terminfo" "$stage_dir/zig-out/share/"
cp "$ghostty_dir/LICENSE" "$stage_dir/LICENSE"

{
  cat "$build_stamp"
  printf 'license: MIT (ghostty-org/ghostty)\n'
} >"$stage_dir/GHOSTTY-MANIFEST.txt"

asset="GhosttyKit-${ghostty_ref}-macos-arm64.tar.gz"
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
  shasum -a 256 "$asset" >"$root_dir/App/ghostty-kit.sha256"
)

size=$(du -h "$tarball" | awk '{print $1}')
sha256=$(awk '{print $1}' "$root_dir/App/ghostty-kit.sha256")
info "成果物: $asset ($size)"
info "sha256: $sha256"
info "App/ghostty-kit.sha256 を更新しました。コミットして PR に含めてください"

release_tag="ghostty-kit-${ghostty_ref}"
release_title="CI 用ビルド成果物: ghostty ${ghostty_ref} (macOS arm64)"
notes="Ghostty ref: ${ghostty_ref}
Commit: ${commit}
License: MIT — https://github.com/ghostty-org/ghostty

CI で App/ をコンパイルするための事前ビルド済み成果物です。"

if [[ "$dry_run" -eq 1 ]]; then
  info "[dry-run] gh release view $release_tag"
  info "[dry-run] 未作成の場合: gh release create $release_tag --title \"$release_title\" --notes <notes> --latest=false"
  info "[dry-run] gh release upload $release_tag $asset --clobber"
  exit 0
fi

if ! gh release view "$release_tag" >/dev/null 2>&1; then
  gh release create "$release_tag" --title "$release_title" --notes "$notes" --latest=false
fi
gh release upload "$release_tag" "$tarball" --clobber
info "publish しました: $release_tag"

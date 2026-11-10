#!/bin/bash
set -euo pipefail

spike_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -z "${AWT_DEVELOPMENT_TEAM:-}" || -z "${AWT_IPAD_XCODEBUILD_ID:-}" || -z "${AWT_IPAD_DEVICECTL_ID:-}" ]]; then
  cat >&2 <<'HELP'
次の環境変数をすべて設定してください。
  AWT_DEVELOPMENT_TEAM: Xcode > Settings > Accounts の Personal Team の Team ID
    既存の署名設定、または Apple Development 証明書の Organizational Unit でも確認できます。
  AWT_IPAD_XCODEBUILD_ID: xcodebuild -showdestinations の id
  AWT_IPAD_DEVICECTL_ID: xcrun devicectl list devices の Identifier (UUID)

初回の destination 確認 (リポジトリ直下から実行):
  cd Spikes/gate2-ipad
  xcodegen generate
  xcodebuild -project Gate2iPad.xcodeproj -scheme Gate2iPad -showdestinations
  xcrun devicectl list devices

xcodebuild の id と devicectl の UUID は別の値です。
HELP
  exit 1
fi

cd "$spike_dir"
xcodegen generate
xcodebuild -project Gate2iPad.xcodeproj -scheme Gate2iPad \
  -configuration Debug \
  -destination "id=${AWT_IPAD_XCODEBUILD_ID}" \
  -derivedDataPath "$spike_dir/DerivedData" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  "DEVELOPMENT_TEAM=${AWT_DEVELOPMENT_TEAM}" build
xcrun devicectl device install app --device "$AWT_IPAD_DEVICECTL_ID" \
  "$spike_dir/DerivedData/Build/Products/Debug-iphoneos/Gate2iPad.app"
xcrun devicectl device process launch --device "$AWT_IPAD_DEVICECTL_ID" \
  --terminate-existing dev.odaryo.awt.spike.gate2ipad

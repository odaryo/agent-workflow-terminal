#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

if [[ -z "${AWT_DEVELOPMENT_TEAM:-}" || -z "${AWT_IPAD_XCODEBUILD_ID:-}" || -z "${AWT_IPAD_DEVICECTL_ID:-}" ]]; then
  cat >&2 <<'USAGE'
AWT_DEVELOPMENT_TEAM / AWT_IPAD_XCODEBUILD_ID / AWT_IPAD_DEVICECTL_ID を設定してください。
  AWT_DEVELOPMENT_TEAM: Xcode の Settings > Accounts に Apple ID を登録し、Personal Team の Team ID を確認します。
  AWT_IPAD_XCODEBUILD_ID: リポジトリ直下で xcodegen generate --spec iOS/project.yml の後、
    xcodebuild -project iOS/AgentWorkflowTerminalMobile.xcodeproj -scheme AgentWorkflowTerminalMobile -showdestinations
    で接続した iPad の id を調べます。
  AWT_IPAD_DEVICECTL_ID: xcrun devicectl list devices の Identifier を使います。
詳しくは iOS/README.md を参照してください。
USAGE
  exit 1
fi

cd "$SCRIPT_DIR/.."
XCODEGEN="${XCODEGEN:-xcodegen}"
command -v "$XCODEGEN" >/dev/null 2>&1 \
  || die "XcodeGen がありません。scripts/fetch-xcodegen.sh <出力ディレクトリ> で取得し、出力されたパスを XCODEGEN に設定してください"

"$XCODEGEN" generate --spec iOS/project.yml
# SwiftTerm の build tool plugin の検証は非対話のビルドでは省略する。
xcodebuild \
  -project iOS/AgentWorkflowTerminalMobile.xcodeproj \
  -scheme AgentWorkflowTerminalMobile \
  -configuration Debug \
  -destination "id=$AWT_IPAD_XCODEBUILD_ID" \
  -derivedDataPath iOS/DerivedData \
  -skipPackagePluginValidation \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  "DEVELOPMENT_TEAM=$AWT_DEVELOPMENT_TEAM" \
  build

xcrun devicectl device install app \
  --device "$AWT_IPAD_DEVICECTL_ID" \
  iOS/DerivedData/Build/Products/Debug-iphoneos/AgentWorkflowTerminalMobile.app
xcrun devicectl device process launch \
  --device "$AWT_IPAD_DEVICECTL_ID" \
  --terminate-existing dev.odaryo.agentworkflowterminal.ios

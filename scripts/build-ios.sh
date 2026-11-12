#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

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
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath iOS/DerivedData \
  -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO \
  build

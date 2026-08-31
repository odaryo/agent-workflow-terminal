// swift-tools-version: 6.0
//
// agent_workflow_terminal の Swift Package。
// 詳細は AgentWorkflowTerminal/README.md および docs/coding-guidelines.md を参照。

import PackageDescription

/// 全ターゲット共通の Swift 設定。
///
/// - `swiftLanguageModes: [.v6]` により strict concurrency (complete) が有効になる。
/// - `ExistentialAny` は `any` の明示を強制し、protocol-oriented な設計方針
///   (docs/coding-guidelines.md) と整合させるために有効化する。
let commonSwiftSettings: [SwiftSetting] = [
  .enableUpcomingFeature("ExistentialAny")
]

let package = Package(
  name: "AgentWorkflowTerminal",
  platforms: [
    .macOS(.v14),
    .iOS(.v17),
  ],
  products: [
    .library(name: "TerminalCore", targets: ["TerminalCore"]),
    .library(name: "Adapters", targets: ["Adapters"]),
  ],
  targets: [
    // ドメインモデル層。UI・外部プロセスへの依存を持たない。
    .target(
      name: "TerminalCore",
      swiftSettings: commonSwiftSettings
    ),
    // 外部世界(tmux / git CLI 等)との境界。TerminalCore にのみ依存する。
    .target(
      name: "Adapters",
      dependencies: ["TerminalCore"],
      swiftSettings: commonSwiftSettings
    ),
    .testTarget(
      name: "TerminalCoreTests",
      dependencies: ["TerminalCore"],
      swiftSettings: commonSwiftSettings
    ),
    .testTarget(
      name: "AdaptersTests",
      dependencies: ["Adapters"],
      swiftSettings: commonSwiftSettings
    ),
  ],
  swiftLanguageModes: [.v6]
)

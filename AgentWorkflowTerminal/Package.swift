// swift-tools-version: 6.0

import PackageDescription

/// strict concurrency をここで指定していないのは、末尾の `swiftLanguageModes: [.v6]` が
/// complete を含むため。`ExistentialAny` は既定では off だが、`any` の明示を強制して
/// protocol 中心の設計 (docs/coding-guidelines.md §2.1) を型で担保するため有効にしている。
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
  // 依存は TerminalCore ← Adapters の一方向だけに保つ。ビルドシステムは逆向きの依存を
  // 検出しないため、ここを目視で守るしかない (docs/coding-guidelines.md §2.2)。
  targets: [
    .target(
      name: "TerminalCore",
      swiftSettings: commonSwiftSettings
    ),
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
      resources: [.copy("Fixtures")],
      swiftSettings: commonSwiftSettings
    ),
  ],
  swiftLanguageModes: [.v6]
)

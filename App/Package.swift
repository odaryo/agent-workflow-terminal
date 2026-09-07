// swift-tools-version: 6.0

import PackageDescription

let commonSwiftSettings: [SwiftSetting] = [
  .enableUpcomingFeature("ExistentialAny")
]

let package = Package(
  name: "AgentWorkflowTerminalApp",
  platforms: [.macOS(.v14)],
  dependencies: [
    .package(path: "../AgentWorkflowTerminal"),
    // syntax highlight (§7.3)。同梱される highlight.js 11.11.1 は BSD-3 で License policy を満たす。
    // JavaScriptCore で highlight.js を評価するため、更新で色付けが変わり得る。版は固定する。
    .package(url: "https://github.com/smittytone/HighlighterSwift", exact: "3.1.0"),
  ],
  targets: [
    .binaryTarget(
      name: "GhosttyKit",
      path: "vendor/ghostty/macos/GhosttyKit.xcframework"
    ),
    .target(
      name: "GhosttyRenderer",
      dependencies: [
        "GhosttyKit",
        .product(name: "TerminalCore", package: "AgentWorkflowTerminal"),
      ],
      // Why not header を修正: vendored v1.3.1 XCFramework は、upstream の umbrella header が
      // 意図的に再 export しない libghostty-vt header を含む。
      swiftSettings: commonSwiftSettings + [
        .unsafeFlags(["-Xcc", "-Wno-incomplete-umbrella"])
      ],
      linkerSettings: [
        .linkedLibrary("ghostty-fat"),
        .linkedLibrary("stdc++"),
        .linkedFramework("Carbon"),
      ]
    ),
    .executableTarget(
      name: "AgentWorkflowTerminalApp",
      dependencies: [
        "GhosttyRenderer",
        .product(name: "Adapters", package: "AgentWorkflowTerminal"),
        .product(name: "Highlighter", package: "HighlighterSwift"),
        .product(name: "TerminalCore", package: "AgentWorkflowTerminal"),
      ],
      swiftSettings: commonSwiftSettings
    ),
  ],
  swiftLanguageModes: [.v6]
)

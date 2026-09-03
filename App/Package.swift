// swift-tools-version: 6.0

import PackageDescription

let commonSwiftSettings: [SwiftSetting] = [
  .enableUpcomingFeature("ExistentialAny")
]

let package = Package(
  name: "AgentWorkflowTerminalApp",
  platforms: [.macOS(.v14)],
  dependencies: [
    .package(path: "../AgentWorkflowTerminal")
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
      dependencies: ["GhosttyRenderer"],
      swiftSettings: commonSwiftSettings
    ),
  ],
  swiftLanguageModes: [.v6]
)

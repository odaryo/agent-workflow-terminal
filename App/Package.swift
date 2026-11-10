// swift-tools-version: 6.0

import PackageDescription

let commonSwiftSettings: [SwiftSetting] = [
  .enableUpcomingFeature("ExistentialAny")
]

// Why not header を修正: vendored v1.3.1 XCFramework は、upstream の umbrella header が
// 意図的に再 export しない libghostty-vt header を含む。GhosttyRenderer を import するだけの
// ターゲットも同じ clang module を読むので、同じ抑止が要る。
let ghosttyClientSwiftSettings =
  commonSwiftSettings + [
    SwiftSetting.unsafeFlags(["-Xcc", "-Wno-incomplete-umbrella"])
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
      swiftSettings: ghosttyClientSwiftSettings,
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
        .product(name: "TerminalCore", package: "AgentWorkflowTerminal"),
      ],
      swiftSettings: ghosttyClientSwiftSettings
    ),
    .testTarget(
      name: "AgentWorkflowTerminalAppTests",
      dependencies: [
        "AgentWorkflowTerminalApp",
        .product(name: "Adapters", package: "AgentWorkflowTerminal"),
        .product(name: "TerminalCore", package: "AgentWorkflowTerminal"),
      ],
      swiftSettings: ghosttyClientSwiftSettings
    ),
    .testTarget(
      name: "GhosttyRendererTests",
      dependencies: [
        "GhosttyRenderer",
        "GhosttyKit",
        .product(name: "TerminalCore", package: "AgentWorkflowTerminal"),
      ],
      swiftSettings: ghosttyClientSwiftSettings
    ),
  ],
  swiftLanguageModes: [.v6]
)

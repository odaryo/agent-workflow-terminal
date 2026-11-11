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
    .executable(name: "hostctl", targets: ["hostctl"]),
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
    .executableTarget(
      name: "hostctl",
      dependencies: ["TerminalCore", "Adapters"],
      swiftSettings: commonSwiftSettings
    ),
    .testTarget(
      name: "TerminalCoreTests",
      dependencies: ["TerminalCore"],
      resources: [.copy("Fixtures")],
      swiftSettings: commonSwiftSettings
    ),
    // 下の2つは TerminalCore を Adapters 経由で推移的に使えるが、直接の依存としても宣言する
    // (Issue #930)。native build system (CI の Swift 6.1.2) は宣言した依存の .swiftmodule だけを
    // コンパイルの入力にする。宣言が無いと、Adapters の公開面が変わらない TerminalCore の変更では
    // このターゲットを再コンパイルせず、古い型の layout のまま結合する。冗長に見えても消さないこと。
    .testTarget(
      name: "AdaptersTests",
      dependencies: ["Adapters", "TerminalCore"],
      resources: [.copy("Fixtures")],
      swiftSettings: commonSwiftSettings
    ),
    // 経過時間 (ContinuousClock) とポーリングの観測回数を主張に使う
    // テストだけを分けている。Swift Testing は同一プロセス内でテストを並行実行するため、
    // AdaptersTests に置いたままでは同時に走る他テストの負荷が観測値へ混ざり、主張の真偽と
    // 無関係に落ちる。CI はこのターゲットだけを --no-parallel で走らせる。
    .testTarget(
      name: "AdaptersSerialTimingTests",
      dependencies: ["Adapters", "TerminalCore"],
      swiftSettings: commonSwiftSettings
    ),
  ],
  swiftLanguageModes: [.v6]
)

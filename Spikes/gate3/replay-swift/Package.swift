// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "replay-swift",
  platforms: [.macOS(.v14)],
  dependencies: [
    .package(path: "../../../AgentWorkflowTerminal")
  ],
  targets: [
    .executableTarget(
      name: "replay-swift",
      dependencies: [.product(name: "TerminalCore", package: "AgentWorkflowTerminal")]
    )
  ],
  swiftLanguageModes: [.v6]
)

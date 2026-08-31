// swift-tools-version: 6.0
import PackageDescription

// Gate 1 PoC (M1)
//
// 構成選択の記録:
//   Xcode プロジェクト (project.pbxproj) を手書きせずに済ませるため SwiftPM の
//   executable target を採用し、`.binaryTarget` で GhosttyKit.xcframework を
//   直接参照している (相対パス `../vendor/...` は SwiftPM に受け入れられる)。
//
//   ただし SwiftPM は static library 形式の XCFramework を build ディレクトリへ
//   コピーするだけでリンクフラグを自動付与しない。そのため `-lghostty-fat` を
//   明示している。Carbon.framework と -lstdc++ は upstream の
//   macos/Ghostty.xcodeproj が明示的にリンクしているものと同じ。
let package = Package(
    name: "TerminalSpike",
    platforms: [.macOS(.v14)],
    targets: [
        .binaryTarget(
            name: "GhosttyKit",
            path: "../vendor/ghostty/macos/GhosttyKit.xcframework"
        ),
        .executableTarget(
            name: "TerminalSpike",
            dependencies: ["GhosttyKit"],
            linkerSettings: [
                .linkedLibrary("ghostty-fat"),
                .linkedLibrary("stdc++"),
                .linkedFramework("Carbon"),
            ]
        ),
    ]
)

import Foundation
import GhosttyKit
import TerminalCore
import Testing

@testable import GhosttyRenderer

/// 設定ファイルが実際に読み込まれ、値が `ghostty_config_*` へ渡ることを、アプリを
/// 起動せずに確かめる (Issue #236)。surface も window も `GHOSTTY_RESOURCES_DIR` も
/// 要らないことは実測済み。
@Suite("端末設定ファイルの読み込み (設計書 §21.6)", .serialized)
@MainActor
struct GhosttyConfigurationLoadingTests {

  @Test("resolve した設定ファイルの font-size が本番の config 構築経路へ渡る")
  func loadsResolvedConfigurationFile() throws {
    // `ghostty_config_new` は libghostty のグローバル allocator を使うので先に初期化する。
    #expect(ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == 0)

    let expected = Float(27.5)
    let configurationHome = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("awt-config-\(UUID().uuidString)", isDirectory: true)
    let directory =
      configurationHome
      .appendingPathComponent("agent-workflow-terminal", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: configurationHome) }
    try "font-size = \(expected)\n"
      .write(
        to: directory.appendingPathComponent("config", isDirectory: false),
        atomically: true,
        encoding: .utf8
      )

    let url = try #require(
      TerminalConfigurationFile.resolve(
        environment: ["XDG_CONFIG_HOME": configurationHome.path],
        fileExists: { FileManager.default.fileExists(atPath: $0) }
      )
    )

    #expect(try configuredFontSize(configurationFileURL: url) == expected)
    // 対照。既定値そのものは libghostty の ref で変わり得るのでアサートしない
    // (2026-09-09 時点の実測は 13.0)。
    #expect(try configuredFontSize(configurationFileURL: nil) != expected)
  }

  /// `font-size` は libghostty 側で `f32` (`src/config/Config.zig`)。`Double` の領域を渡すと
  /// `ghostty_config_get` は 4 byte だけ書いて `true` を返し、残りは未初期化のまま読める。
  private func configuredFontSize(configurationFileURL: URL?) throws -> Float {
    let config = try makeGhosttyConfiguration(configurationFileURL: configurationFileURL)
    defer { ghostty_config_free(config) }
    let key = "font-size"
    var value = Float.nan
    #expect(ghostty_config_get(config, &value, key, UInt(key.utf8.count)))
    return value
  }
}

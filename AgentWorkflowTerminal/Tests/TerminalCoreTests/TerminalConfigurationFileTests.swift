import Foundation
import TerminalCore
import Testing

@Suite("端末設定ファイルの経路 (設計書 §21.6)")
struct TerminalConfigurationFileTests {

  private static let expectedSuffix = "agent-workflow-terminal/config"

  private func resolve(
    _ environment: [String: String],
    existing: Set<String> = []
  ) -> URL? {
    TerminalConfigurationFile.resolve(
      environment: environment,
      fileExists: { existing.contains($0) }
    )
  }

  @Test("XDG_CONFIG_HOME があればそれを基点にする")
  func usesXDGConfigHome() throws {
    let path = "/xdg/\(Self.expectedSuffix)"
    let url = try #require(
      resolve(["XDG_CONFIG_HOME": "/xdg", "HOME": "/home/me"], existing: [path])
    )
    #expect(url.path == path)
  }

  @Test("XDG_CONFIG_HOME が空文字なら未設定と同じく HOME/.config を基点にする")
  func emptyXDGConfigHomeFallsBackToHome() throws {
    let path = "/home/me/.config/\(Self.expectedSuffix)"
    let url = try #require(
      resolve(["XDG_CONFIG_HOME": "", "HOME": "/home/me"], existing: [path])
    )
    #expect(url.path == path)
  }

  @Test("XDG_CONFIG_HOME が無ければ HOME/.config を基点にする")
  func usesHomeConfig() throws {
    let path = "/home/me/.config/\(Self.expectedSuffix)"
    let url = try #require(resolve(["HOME": "/home/me"], existing: [path]))
    #expect(url.path == path)
  }

  @Test("基点が決まらなければ nil", arguments: [[:], ["HOME": ""]] as [[String: String]])
  func withoutAnyBase(_ environment: [String: String]) {
    // fileExists が常に true でも nil。基点が無いまま相対パスを組み立てない。
    #expect(
      TerminalConfigurationFile.resolve(environment: environment, fileExists: { _ in true })
        == nil
    )
  }

  @Test("ファイルが無ければ nil")
  func missingFile() {
    #expect(resolve(["HOME": "/home/me"]) == nil)
  }

  @Test("ghostty 本体の設定ファイルは見に行かない")
  func doesNotLookAtGhosttyOwnFiles() {
    // 存在するのは ghostty 側の3経路だけ、という環境を作る。
    let ghosttyFiles: Set<String> = [
      "/xdg/ghostty/config",
      "/xdg/ghostty/config.ghostty",
      "/home/me/Library/Application Support/com.mitchellh.ghostty/config",
    ]
    let environment = ["XDG_CONFIG_HOME": "/xdg", "HOME": "/home/me"]
    #expect(resolve(environment, existing: ghosttyFiles) == nil)
  }
}

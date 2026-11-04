import Adapters
import Foundation
import Testing

@testable import AgentWorkflowTerminalApp

@Suite("tmux の設定と起動時の案内 (§4.3)")
struct TmuxSettingsTests {
  @Test("見つからないときは探索順と導入方法と設定先を案内する")
  func notFoundMessage() {
    let searched = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"].map {
      URL(fileURLWithPath: $0)
    }
    #expect(
      TmuxSettings.failureMessage(for: .notFound(searched: searched))
        == "tmux 実行ファイルが見つかりません。探した場所: /opt/homebrew/bin/tmux、/usr/local/bin/tmux。"
        + "Homebrew では `brew install tmux` で導入できます。"
        + "別の場所にある tmux を使うときは、設定の「tmux」でパスを指定してください。")
  }

  @Test(
    "上書きを使えないときはパスと理由と直し方を案内する",
    arguments: [
      (TmuxExecutableResolution.OverrideProblem.notAbsolute, "絶対パスではありません"),
      (.isDirectory, "ディレクトリです。tmux の実行ファイルのパスを指定してください"),
      (.notExecutable, "存在しないか、実行できません"),
    ])
  func overrideFailureMessage(
    reason: TmuxExecutableResolution.OverrideProblem, explanation: String
  ) {
    let path = "/custom/tmux"
    #expect(
      TmuxSettings.failureMessage(for: .overrideNotUsable(path: path, reason: reason))
        == "設定で指定した tmux を使えません (\(path)): \(explanation)。"
        + "設定の「tmux」でパスを直すか、空にして既定の場所を探させてください。")
  }

  @Test(
    "見つかったときはエラー文を返さない",
    arguments: [
      TmuxExecutableResolution.Source.override, .defaultCandidate,
    ])
  func foundHasNoMessage(source: TmuxExecutableResolution.Source) {
    #expect(
      TmuxSettings.failureMessage(
        for: .found(URL(fileURLWithPath: "/custom/tmux"), source: source)) == nil)
  }

  @Test("未設定と空欄は上書きなし、それ以外は保存値を返す")
  func overridePreference() throws {
    let suiteName = "TmuxSettingsTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(TmuxPreferences.overridePath(defaults) == nil)
    defaults.set("/custom/tmux", forKey: TmuxPreferences.executablePathKey)
    #expect(TmuxPreferences.overridePath(defaults) == "/custom/tmux")
    defaults.set("", forKey: TmuxPreferences.executablePathKey)
    #expect(TmuxPreferences.overridePath(defaults) == nil)
  }

  @Test(
    "実行ファイルと実行不可とディレクトリを区別し、symlink は参照先を見る",
    arguments: [
      ("executable", TmuxExecutableFileKind.executableFile),
      ("non-executable", .unusable), ("directory", .directory),
      ("directory-link", .directory), ("missing", .unusable),
    ])
  func fileKind(name: String, expected: TmuxExecutableFileKind) throws {
    let manager = FileManager.default
    let temporary = manager.temporaryDirectory.appending(path: UUID().uuidString)
    try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: temporary) }

    let executable = temporary.appending(path: "executable")
    try Data().write(to: executable)
    try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let nonExecutable = temporary.appending(path: "non-executable")
    try Data().write(to: nonExecutable)
    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: nonExecutable.path)
    let directory = temporary.appending(path: "directory")
    try manager.createDirectory(at: directory, withIntermediateDirectories: false)
    try manager.createSymbolicLink(
      at: temporary.appending(path: "directory-link"), withDestinationURL: directory)

    #expect(TmuxSettings.fileKind(temporary.appending(path: name).path) == expected)
  }
}

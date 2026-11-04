import Adapters
import Foundation
import Testing

@testable import AgentWorkflowTerminalApp

@Suite("§4.3 / §17.3 ツールの版数の警告")
struct ToolVersionWarningsTests {
  @Test("サポート対象の版には警告しない")
  func supported() {
    #expect(ToolVersionWarnings.tmux(.success(.supported(.init(major: 3, minor: 5)))) == nil)
    #expect(
      ToolVersionWarnings.git(.success(.supported(.init(major: 2, minor: 39, patch: 0)))) == nil)
  }

  @Test("tmux の下限未満は更新を勧める")
  func unsupportedTmux() {
    let result: TmuxVersionSupport = .unsupported(
      .init(major: 3, minor: 3, suffix: "a"), minimum: .minimumSupported)
    #expect(
      ToolVersionWarnings.tmux(.success(result))
        == "tmux 3.3a はサポート下限の 3.4 より古いため、表示や操作が正しく動かないことがあります。"
        + "tmux を更新してください (Homebrew では `brew upgrade tmux`)。")
  }

  @Test("tmux の ZWJ 警告は機能を制限しない")
  func tmuxZeroWidthJoiner() {
    let result: TmuxVersionSupport = .supportedWithWarnings(
      .init(major: 3, minor: 4), [.zeroWidthJoinerGraphemeWidth])
    #expect(
      ToolVersionWarnings.tmux(.success(result))
        == "tmux 3.4 では、ZWJ を含む絵文字 (👨‍👩‍👧‍👦 など) の表示幅がずれることがあります。"
        + "3.5 以降で改善しています。機能の制限はありません。")
    #expect(
      ToolVersionWarnings.tmux(
        .success(.supportedWithWarnings(.init(major: 3, minor: 4), []))) == nil)
  }

  @Test("git の下限未満は更新を勧める")
  func unsupportedGit() {
    let result: GitVersionSupport = .unsupported(
      .init(major: 2, minor: 38, patch: 1), minimum: .minimumSupported)
    #expect(
      ToolVersionWarnings.git(.success(result))
        == "git 2.38.1 はサポート下限の 2.39.0 より古いため、Diff や File Browser が正しく動かないことがあります。"
        + "git を更新してください。")
  }

  @Test("解釈不能は対象内にも対象外にも丸めず出力を示す")
  func unknown() throws {
    let tmux = try #require(ToolVersionWarnings.tmux(.success(.unknown(rawOutput: "tmux next"))))
    let git = try #require(ToolVersionWarnings.git(.success(.unknown(rawOutput: "git custom"))))
    #expect(
      tmux == "tmux の版数を解釈できませんでした (`tmux -V` の出力: tmux next)。"
        + "対応している版かどうかは確かめられていません。")
    #expect(
      git == "git の版数を解釈できませんでした (`git --version` の出力: git custom)。"
        + "対応している版かどうかは確かめられていません。")
    for warning in [tmux, git] {
      #expect(!warning.contains("対象"))
      #expect(!warning.contains("更新してください"))
    }
  }

  @Test(
    "解釈不能の出力は前後を除去し改行を空白にする",
    arguments: [" \ncustom\nversion\t ", "\tcustom\r\nversion\r", "custom\rversion"])
  func unknownNewlines(rawOutput: String) {
    #expect(
      ToolVersionWarnings.tmux(.success(.unknown(rawOutput: rawOutput)))
        == "tmux の版数を解釈できませんでした (`tmux -V` の出力: custom version)。"
        + "対応している版かどうかは確かめられていません。")
    #expect(
      ToolVersionWarnings.git(.success(.unknown(rawOutput: rawOutput)))
        == "git の版数を解釈できませんでした (`git --version` の出力: custom version)。"
        + "対応している版かどうかは確かめられていません。")
  }

  @Test("出力は80文字まで保持し81文字以上なら省略記号を付ける", arguments: [80, 81, 120])
  func unknownTruncation(count: Int) {
    let rawOutput = String(repeating: "あ", count: count)
    let output = String(repeating: "あ", count: 80) + (count > 80 ? "…" : "")
    #expect(
      ToolVersionWarnings.tmux(.success(.unknown(rawOutput: rawOutput)))
        == "tmux の版数を解釈できませんでした (`tmux -V` の出力: \(output))。"
        + "対応している版かどうかは確かめられていません。")
    #expect(
      ToolVersionWarnings.git(.success(.unknown(rawOutput: rawOutput)))
        == "git の版数を解釈できませんでした (`git --version` の出力: \(output))。"
        + "対応している版かどうかは確かめられていません。")
  }

  @Test(
    "tmux の検出失敗にはエラーを添える",
    arguments: [
      TmuxRunnerError.process(.timedOut(exitCode: nil, stdout: "", stderr: "")),
      .commandFailed(exitCode: 1, stdout: "", stderr: "failed"),
      .binaryNotFound(candidates: [URL(fileURLWithPath: "/missing/tmux")]),
      .invalidSocketName("invalid"),
    ])
  func tmuxFailure(error: TmuxRunnerError) {
    #expect(
      ToolVersionWarnings.tmux(.failure(error)) == "tmux の版数を確かめられませんでした: \(error)")
  }

  @Test("git が見つからないときは探したパスを列挙する")
  func missingGit() {
    let candidates = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
      .map { URL(fileURLWithPath: $0) }
    #expect(
      ToolVersionWarnings.git(.failure(.binaryNotFound(candidates: candidates)))
        == "git 実行ファイルが見つかりません。探した場所: /opt/homebrew/bin/git、/usr/local/bin/git、/usr/bin/git。")
  }

  @Test(
    "git の検出失敗にはエラーを添える",
    arguments: [
      GitVersionDetectionError.process(.timedOut(exitCode: nil, stdout: "", stderr: "")),
      .commandFailed(exitCode: 1, stdout: "", stderr: "failed"),
    ])
  func gitFailure(error: GitVersionDetectionError) {
    #expect(
      ToolVersionWarnings.git(.failure(error)) == "git の版数を確かめられませんでした: \(error)")
  }
}

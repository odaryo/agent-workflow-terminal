import Adapters
import Foundation
import Testing

@testable import AgentWorkflowTerminalApp

/// blame の表示行 (§7.3)。porcelain の解析結果から、注記を付ける行と履歴へ移るときのパスを決める。
@Suite("§7.3 blame の表示行")
struct CodeBlameRowsTests {
  private static let first = String(repeating: "a", count: 40)
  private static let second = String(repeating: "b", count: 40)

  @Test("注記は同じ commit が続く行の先頭にだけ付け、塊ごとに通し番号を振る")
  func annotatesFirstLineOfEachRun() {
    let output =
      [
        "\(Self.first) 1 1 2", "author A", "author-time 0", "summary s", "filename new",
        "previous \(Self.second) old", "\tl1",
        "\(Self.first) 2 2", "\tl2",
        "\(Self.second) 1 3 1", "author B", "author-time 0", "summary t", "filename old", "\tl3",
      ].joined(separator: "\n") + "\n"
    let rows = CodeHistoryModel.rows(of: GitBlamePorcelain.parse(output: output))

    #expect(rows.map(\.id) == [1, 2, 3])
    #expect(rows.map { $0.annotation != nil } == [true, false, true])
    #expect(rows.map(\.runIndex) == [0, 0, 1])
    // rename 元も渡さないと、`--no-walk` で rename の commit が追加に見える。
    #expect(rows.first?.annotation?.paths == ["new", "old"])
    #expect(rows.last?.annotation?.paths == ["old"])
  }

  @Test("制御文字は Control Pictures に、タブは空白に置き換えて表示する")
  func replacesControlCharacters() {
    #expect(displayText("a\tb\u{1B}[31m\u{1F}\u{7F}日本") == "a b\u{241B}[31m\u{241F}\u{2421}日本")
  }

  @Test("git の失敗は stderr をそのまま出す")
  func showsRawStderr() {
    let message = CodeHistoryModel.message(
      for: .git(.commandFailed(exitCode: 128, stdout: "", stderr: "fatal: no such path 'x'\n")))

    #expect(message == "fatal: no such path 'x'\n")
  }
}

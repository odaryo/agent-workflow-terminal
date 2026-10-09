import Adapters
import Foundation
import Testing

// fixture は `GitFileHistoryTests` と同じ隔離 repository から 2.50.1 / 2.55.0 で採取した。
// `git --no-optional-locks -C <root> --no-pager -c core.quotePath=false blame --porcelain --no-root
// --encoding=UTF-8 -- <path>`。`uncommitted` は working tree に1行足した状態で取っている。
@Suite("§7.3 blame (porcelain) の解析")
struct GitBlamePorcelainTests {
  private static let versions = ["2.50.1", "2.55.0"]

  @Test("行ごとに commit・元の行番号・元のパス・本文を持つ", arguments: versions)
  func parsesLines(version: String) throws {
    let result = GitBlamePorcelain.parse(
      output: try fixture(named: "git-\(version)-blame-porcelain-uncommitted.txt"))

    #expect(result.failures.isEmpty)
    #expect(result.lines.map(\.finalLineNumber) == [1, 2, 3, 4, 5, 6])
    #expect(
      result.lines.map(\.content) == [
        "one main", "two changed", "three", "four", "five side", "uncommitted line",
      ])
    #expect(
      result.lines.map { String($0.commitID.prefix(7)) } == [
        "91f55f2", "afe078f", "ec8f58e", "ec8f58e", "066cbda", "0000000",
      ])
    #expect(result.lines.map(\.originalLineNumber) == [1, 2, 3, 4, 5, 6])
    // rename 前の commit に帰属する行は、その時点のパスを持つ。group の2行目
    // (メタデータを繰り返さない行) も同じパスを引き継ぐ。
    #expect(
      result.lines.map(\.path) == [
        "src/new name é.txt", "src/old name ä.txt", "src/old name ä.txt", "src/old name ä.txt",
        "src/new name é.txt", "src/new name é.txt",
      ])
  }

  @Test("commit ごとのメタデータを、制御文字を含めてそのまま保持する", arguments: versions)
  func parsesCommitMetadata(version: String) throws {
    let result = GitBlamePorcelain.parse(
      output: try fixture(named: "git-\(version)-blame-porcelain-uncommitted.txt"))
    #expect(result.lines.count == 6)
    let tabbed = try #require(result.lines.dropFirst().first.flatMap(result.commit(for:)))
    let side = try #require(result.lines.dropFirst(4).first.flatMap(result.commit(for:)))

    #expect(tabbed.authorName == "Tab\tAuthor 日本")
    #expect(tabbed.authoredAt == Date(timeIntervalSince1970: 1_767_312_000))
    #expect(tabbed.summary == "summary\twith tab \u{01}ctl \u{1B}[31m esc 非ASCII")
    #expect(
      tabbed.previous
        == GitBlamePrevious(
          commitID: "ec8f58e2a71648122f6c6b0d78b953c2620fc529", path: "src/old name ä.txt"))
    #expect(side.authorName == "Ctl\u{01}\u{1F}Side")
    #expect(side.summary == "side\u{1F}change\u{1E}rs")
    #expect(!tabbed.isUncommitted)
    #expect(!tabbed.isBoundary)
  }

  @Test("未commit の行は全桁 0 の OID として区別する", arguments: versions)
  func distinguishesUncommittedLines(version: String) throws {
    let result = GitBlamePorcelain.parse(
      output: try fixture(named: "git-\(version)-blame-porcelain-uncommitted.txt"))
    let last = try #require(result.lines.last)
    let commit = try #require(result.commit(for: last))

    #expect(commit.isUncommitted)
    #expect(result.lines.dropLast().allSatisfy { result.commit(for: $0)?.isUncommitted == false })
  }

  @Test("root commit は --no-root により boundary として印が付く", arguments: versions)
  func marksBoundary(version: String) throws {
    let result = GitBlamePorcelain.parse(
      output: try fixture(named: "git-\(version)-blame-porcelain-uncommitted.txt"))
    let boundaries = result.lines.filter { result.commit(for: $0)?.isBoundary == true }

    #expect(boundaries.map(\.finalLineNumber) == [3, 4])
  }

  @Test("引用されたファイル名を復号し、CRLF の CR を本文に残す", arguments: versions)
  func unquotesFileNameAndKeepsCarriageReturn(version: String) throws {
    let result = GitBlamePorcelain.parse(
      output: try fixture(named: "git-\(version)-blame-porcelain-quoted-crlf.txt"))

    #expect(result.failures.isEmpty)
    #expect(result.lines.map(\.content) == ["crlf 1\r", "crlf 2 changed\r", "no newline"])
    #expect(result.lines.allSatisfy { $0.path == "src/q\"uote.txt" })
    let changed = try #require(result.commit(for: result.lines[1]))
    #expect(changed.previous?.path == "src/q\"uote.txt")
  }

  @Test("壊れたヘッダは部分失敗にし、次の本文行までを読み飛ばして続ける")
  func reportsBrokenHeader() {
    let oid = String(repeating: "a", count: 40)
    let output =
      [
        "zzzz 1 1 1", "author x", "\tbroken",
        "\(oid) 1 2 1", "author A", "author-time 0", "summary s", "filename f", "\tkept",
      ].joined(separator: "\n") + "\n"
    let result = GitBlamePorcelain.parse(output: output)

    #expect(result.lines.map(\.content) == ["kept"])
    #expect(result.failures.map(\.lineNumber) == [1])
    #expect(result.failures.first?.error == .invalidHeader("zzzz 1 1 1"))
  }

  @Test("本文行の前で出力が切れた entry は失敗にする")
  func reportsMissingContent() {
    let oid = String(repeating: "a", count: 40)
    let result = GitBlamePorcelain.parse(output: "\(oid) 1 1 1\nauthor A\n")

    #expect(result.lines.isEmpty)
    #expect(result.failures.first?.error == .missingContent)
  }

  private func fixture(named name: String) throws -> String {
    let url = try #require(
      Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return String(decoding: try Data(contentsOf: url), as: UTF8.self)
  }
}

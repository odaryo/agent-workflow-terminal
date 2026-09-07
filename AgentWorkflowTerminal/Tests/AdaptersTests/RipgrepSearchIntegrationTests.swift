import Foundation
import TerminalCore
import Testing

@testable import Adapters

// 実 rg を必要とするため opt-in。`AWT_RIPGREP_INTEGRATION=1 swift test` で有効になる。
private let isRipgrepIntegrationEnabled =
  ProcessInfo.processInfo.environment["AWT_RIPGREP_INTEGRATION"] == "1"

@Suite(
  "§8 実 ripgrep に対する検索",
  .enabled(if: isRipgrepIntegrationEnabled)
)
struct RipgrepSearchIntegrationTests {
  @Test("gitignore 尊重 scope と全ファイル scope が観測できる集合を変える")
  func scopeChangesObservedSet() async throws {
    try await withFixtureWorktree { search in
      let respecting = try await search.search(
        try #require(WorktreeSearchQuery(term: "hello", scope: .respectingGitignore)))
      let all = try await search.search(
        try #require(WorktreeSearchQuery(term: "hello", scope: .allFiles)))
      let respectingPaths = Set(respecting.outcome.matches.map(\.path.value))
      let allPaths = Set(all.outcome.matches.map(\.path.value))
      #expect(respectingPaths.contains("a.txt"))
      #expect(!respectingPaths.contains("ignored.txt"))
      #expect(allPaths.contains("ignored.txt"))
      #expect(allPaths.contains(".hidden.txt"))
      #expect(!allPaths.contains(".git/config"))
    }
  }

  @Test("1ファイル上限の打ち切りが実出力から確定する")
  func detectsPerFileTruncation() async throws {
    try await withFixtureWorktree { search in
      let report = try await search.search(
        try #require(WorktreeSearchQuery(term: "hello", scope: .respectingGitignore)),
        perFileLimit: 100)
      #expect(report.outcome.truncation.filesReachingPerFileLimit.map(\.value) == ["many.txt"])
      #expect(report.outcome.matches.filter { $0.path.value == "many.txt" }.count == 100)
    }
  }

  @Test("非 UTF-8 の行でもマッチ位置が行テキストの上に載る")
  func mapsOffsetsOnLossyLine() async throws {
    try await withFixtureWorktree { search in
      let report = try await search.search(
        try #require(WorktreeSearchQuery(term: "hello", scope: .respectingGitignore)))
      let match = try #require(report.outcome.matches.first { $0.path.value == "nonutf8.txt" })
      let range = try #require(match.line.matches.first)
      #expect(String(match.line.text[range]) == "hello")
    }
  }

  @Test("長い行は表示幅で切り、切ったことが結果に出る")
  func truncatesLongLine() async throws {
    try await withFixtureWorktree { search in
      let report = try await search.search(
        try #require(WorktreeSearchQuery(term: "hello", scope: .respectingGitignore)))
      let match = try #require(report.outcome.matches.first { $0.path.value == "long.txt" })
      #expect(match.line.isTruncated)
      #expect(match.line.text.count == WorktreeSearchLimits.maximumDisplayedColumns)
    }
  }

  @Test("正規表現の切り替えが観測できる集合を変える")
  func regularExpressionToggle() async throws {
    try await withFixtureWorktree { search in
      let literal = try await search.search(
        try #require(WorktreeSearchQuery(term: "h.llo", scope: .respectingGitignore)))
      let regular = try await search.search(
        try #require(
          WorktreeSearchQuery(
            term: "h.llo", scope: .respectingGitignore, usesRegularExpression: true)))
      #expect(literal.outcome.matches.isEmpty)
      #expect(!regular.outcome.matches.isEmpty)
    }
  }

  @Test("不正な正規表現は commandFailed になり、0 件と混ざらない")
  func invalidRegularExpression() async throws {
    try await withFixtureWorktree { search in
      await #expect(throws: RipgrepRunnerError.self) {
        _ = try await search.search(
          try #require(
            WorktreeSearchQuery(
              term: "[", scope: .respectingGitignore, usesRegularExpression: true)))
      }
    }
  }

  @Test("ファイル一覧は scope に従い、.git/ を含まない")
  func listsFiles() async throws {
    try await withFixtureWorktree { search in
      let respecting = try await search.listFiles(scope: .respectingGitignore)
      let all = try await search.listFiles(scope: .allFiles)
      #expect(!respecting.paths.map(\.value).contains("ignored.txt"))
      #expect(all.paths.map(\.value).contains("ignored.txt"))
      #expect(!all.paths.map(\.value).contains(".git/config"))
    }
  }

  private func withFixtureWorktree(
    _ body: (RipgrepSearch) async throws -> Void
  ) async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "awt-rg-it-" + UUID().uuidString)
    let manager = FileManager.default
    try manager.createDirectory(at: root.appending(path: "sub"), withIntermediateDirectories: true)
    try manager.createDirectory(at: root.appending(path: ".git"), withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }

    func write(_ bytes: [UInt8], _ name: String) throws {
      try Data(bytes).write(to: root.appending(path: name))
    }
    try write(Array("hello world\nhello again\n".utf8), "a.txt")
    try write(Array("マルチバイト hello テスト\n日本語 hello\n".utf8), "mb.txt")
    try write(Array("ignored hello\n".utf8), "ignored.txt")
    try write(Array("ignored.txt\n".utf8), ".gitignore")
    try write(Array("hidden hello\n".utf8), ".hidden.txt")
    try write(Array("git internal hello\n".utf8), ".git/config")
    try write(Array("nested hello\n".utf8), "sub/b.txt")
    try write(Array("prefix ".utf8) + [0xFF, 0xFE] + Array(" hello tail\n".utf8), "nonutf8.txt")
    try write(
      Array(
        (String(repeating: "x", count: 600) + " hello "
          + String(repeating: "y", count: 600) + "\n").utf8), "long.txt")
    try write(
      Array((1...129).map { "line \($0) hello\n" }.joined().utf8), "many.txt")

    try await body(
      try RipgrepSearch(worktreeRoot: root, processRunner: FoundationProcessRunner()))
  }
}

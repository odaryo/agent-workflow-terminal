import Foundation
import TerminalCore
import Testing

@testable import AgentWorkflowTerminalApp

@Suite("Diff の選択行の本文コピー (Issue #228)", .serialized)
@MainActor
struct DiffSelectedLinesTextTests {
  @Test("行選択が無いときは本文を返さない")
  func noSelectionReturnsNil() async throws {
    let repository = try TemporaryRepository.make()
    defer { repository.cleanUp() }
    let model = try await openModel(repository)

    #expect(model.lineSelection == nil)
    #expect(model.selectedLinesText == nil)
  }

  @Test("new 側の1行は符号を含まない本文になる")
  func newLineReturnsText() async throws {
    let repository = try TemporaryRepository.make()
    defer { repository.cleanUp() }
    let model = try await openModel(repository)

    model.selectLine(2, side: .new)

    #expect(model.selectedLinesText == "追加した行")
  }

  @Test("new 側の範囲は LF で繋ぎ、符号・改行なし表示・末尾改行を含まない")
  func newRangeJoinsTextWithoutTrailingNewline() async throws {
    let repository = try TemporaryRepository.make()
    defer { repository.cleanUp() }
    let model = try await openModel(repository)

    model.selectLine(1, side: .new)
    model.extendSelection(to: 3, side: .new)

    #expect(model.selectedLinesText == "共通の行\n追加した行\n最後の行")
  }

  @Test("old 側の削除行は削除された本文になる")
  func oldLineReturnsDeletedText() async throws {
    let repository = try TemporaryRepository.make()
    defer { repository.cleanUp() }
    let model = try await openModel(repository)

    model.selectLine(2, side: .old)

    #expect(model.selectedLinesText == "削除された行")
  }

  @Test("範囲にその側の行が揃わないときは本文を返さない", arguments: [DiffLineSide.new, .old])
  func missingLinesReturnNil(side: DiffLineSide) async throws {
    let repository = try TemporaryRepository.make()
    defer { repository.cleanUp() }
    let model = try await openModel(repository)

    model.selectLine(2, side: side)
    model.extendSelection(to: 4, side: side)

    #expect(model.selectedLinesText == nil)
  }

  @Test("行選択があっても snapshot が無いときは本文を返さない")
  func missingSnapshotReturnsNil() async throws {
    let repository = try TemporaryRepository.make()
    defer { repository.cleanUp() }
    let model = try await openModel(repository)
    model.selectLine(2, side: .new)
    #expect(model.selectedLinesText == "追加した行")

    model.currentSnapshotID = DiffSnapshotID(rawValue: UUID())

    #expect(model.lineSelection != nil)
    #expect(model.currentSnapshot == nil)
    #expect(model.selectedLinesText == nil)
  }

  private func openModel(_ repository: TemporaryRepository) async throws -> DiffViewerModel {
    let model = DiffViewerModel(worktreeRoot: repository.root)
    model.kind = .commit
    await model.prepareForDisplay()
    _ = try #require(model.currentSnapshot)
    let selection = try #require(model.selection)
    #expect(selection.path == "file.txt")
    return model
  }
}

/// `DiffViewerModel` の git 呼び出しは実プロセス固定なので、一時リポジトリで snapshot を作る。
private struct TemporaryRepository {
  let root: URL

  static func make() throws -> Self {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("awt-diff-copy-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let repository = Self(root: root)
    do {
      try repository.git(["init", "-q", "-b", "main"])
      try repository.commit(text: "共通の行\n削除された行\n最後の行\n", message: "before")
      try repository.commit(text: "共通の行\n追加した行\n最後の行", message: "after")
    } catch {
      repository.cleanUp()
      throw error
    }
    return repository
  }

  func cleanUp() {
    try? FileManager.default.removeItem(at: root)
  }

  private func commit(text: String, message: String) throws {
    try Data(text.utf8).write(to: root.appendingPathComponent("file.txt"), options: .atomic)
    try git(["add", "file.txt"])
    try git(["commit", "-q", "-m", message])
  }

  private func git(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments =
      [
        "-c", "user.name=awt test", "-c", "user.email=awt@example.invalid",
        "-c", "commit.gpgsign=false",
      ] + arguments
    process.currentDirectoryURL = root
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0, "git \(arguments.joined(separator: " "))")
  }
}

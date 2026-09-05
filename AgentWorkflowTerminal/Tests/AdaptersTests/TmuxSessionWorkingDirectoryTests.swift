import Foundation
import TerminalCore
import Testing

@testable import Adapters

@Suite("設計書 §3.3 の session 作成が作業ディレクトリを tmux へ渡す前に行う検証")
struct TmuxSessionWorkingDirectoryTests: TmuxSessionOperationsTestSupport {

  // MARK: - 値の形

  @Test(
    "pane が渡した値を得られない作業ディレクトリを tmux へ渡さない",
    arguments: ["/repo/wt;", "", "/repo/wt/#[fg=red]", "/repo/#[", "/repo/wt/a##[b"]
  )
  func rejectsWorkingDirectoryAlteredByTmux(path: String) async throws {
    let stub = TmuxSessionRunnerStub(result: stubSuccess())
    let operations = try makeOperations(stub)

    await #expect(throws: TmuxSessionOperationError.invalidWorkingDirectory(path)) {
      try await operations.create(session: try sessionName(), workingDirectory: path)
    }
    #expect(await stub.invocations.isEmpty)
  }

  @Test(
    "pane がそのまま受け取れる作業ディレクトリは弾かない",
    arguments: ["/repo/mid;dir", "/repo/wt\\", "/repo/wt/a\\b", "/repo/wt/#", "/repo/wt/#123"]
  )
  func allowsWorkingDirectoryPreservedByTmux(path: String) async throws {
    let name = try sessionName()
    let stub = TmuxSessionRunnerStub(handler: createHandler(name: name))

    try await makeOperations(stub).create(session: name, workingDirectory: path)

    #expect(await stub.invocations.count == 3)
  }

  @Test("値の形の不正は、そのディレクトリへ入れないことより先に返す")
  func rejectsMalformedValueBeforeCheckingTheFileSystem() async throws {
    let stub = TmuxSessionRunnerStub(result: stubSuccess())
    let operations = try makeOperations(stub, canEnterDirectory: { _ in false })

    await #expect(throws: TmuxSessionOperationError.invalidWorkingDirectory("")) {
      try await operations.create(session: try sessionName(), workingDirectory: "")
    }
    #expect(await stub.invocations.isEmpty)
  }

  // MARK: - ファイルシステム上の実体

  @Test("作業ディレクトリへ入れなければ tmux を起動する前に失敗する")
  func rejectsUnusableWorkingDirectory() async throws {
    let stub = TmuxSessionRunnerStub(result: stubSuccess())
    let operations = try makeOperations(stub, canEnterDirectory: { _ in false })

    await #expect(throws: TmuxSessionOperationError.workingDirectoryUnusable(workingDirectory)) {
      try await operations.create(session: try sessionName(), workingDirectory: workingDirectory)
    }
    #expect(await stub.invocations.isEmpty)
  }

  @Test(
    "pane が chdir できる実体だけを tmux へ渡す",
    arguments: EnterablePath.allCases
  )
  func acceptsPathsThePaneCanEnter(path: EnterablePath) async throws {
    let name = try sessionName()
    let stub = TmuxSessionRunnerStub(handler: createHandler(name: name))

    try await withTemporaryTree { root in
      try await makeOperationsWithFileSystem(stub).create(
        session: name, workingDirectory: try path.make(in: root))
    }

    #expect(await stub.invocations.count == 3)
  }

  @Test(
    "pane が chdir できない実体は tmux を撃つ前に弾く",
    arguments: UnenterablePath.allCases
  )
  func rejectsPathsThePaneCannotEnter(path: UnenterablePath) async throws {
    let stub = TmuxSessionRunnerStub(result: stubSuccess())
    let operations = try makeOperationsWithFileSystem(stub)

    try await withTemporaryTree { root in
      let directory = try path.make(in: root)
      await #expect(throws: TmuxSessionOperationError.workingDirectoryUnusable(directory)) {
        try await operations.create(session: try sessionName(), workingDirectory: directory)
      }
    }

    #expect(await stub.invocations.isEmpty)
  }

  // MARK: - 実ファイルの fixture

  /// tmux 3.4 実測で pane がその場所に入れたパス。
  enum EnterablePath: String, Sendable, CaseIterable {
    case searchableDirectory
    /// 読み取り権限が無くても pane は入る。述語が `R_OK` を要求していれば落ちる。
    case searchOnlyDirectory
    case symbolicLinkToDirectory

    func make(in root: URL) throws -> String {
      switch self {
      case .searchableDirectory: return try makeDirectory(rawValue, mode: 0o700, in: root)
      case .searchOnlyDirectory: return try makeDirectory(rawValue, mode: 0o100, in: root)
      case .symbolicLinkToDirectory:
        let target = try makeDirectory("\(rawValue)-target", mode: 0o700, in: root)
        let link = root.appending(path: rawValue)
        try FileManager.default.createSymbolicLink(
          at: link, withDestinationURL: URL(fileURLWithPath: target))
        return link.path
      }
    }
  }

  /// tmux 3.4 実測で pane が `$HOME` へ落ちたパス。tmux 自身は exit 0 を返す。
  ///
  /// `unsearchableDirectory` と `readOnlyDirectory` は**テストプロセスが root でない**ことを前提に
  /// する。`access(2)` は appropriate privileges を持つプロセスには実行ビットが無くても `X_OK` の
  /// 成功を返し得ると規定しており (macOS `man 2 access`)、root ではこの2件が弾かれなくなる。
  /// root での実測は行っていない。CI の macOS runner もローカルも非 root で走るため、前提を
  /// 書くだけに留める。
  enum UnenterablePath: String, Sendable, CaseIterable {
    case unsearchableDirectory
    /// 読み取りだけでは chdir できない。存否だけを見る述語はここを通してしまう。
    case readOnlyDirectory
    /// 実行ビットの立った通常ファイルには `X_OK` が立つ。ディレクトリ判定と併せて初めて弾ける。
    case executableRegularFile
    case symbolicLinkToUnsearchableDirectory
    case missingPath

    func make(in root: URL) throws -> String {
      switch self {
      case .unsearchableDirectory: return try makeDirectory(rawValue, mode: 0o000, in: root)
      case .readOnlyDirectory: return try makeDirectory(rawValue, mode: 0o400, in: root)
      case .executableRegularFile:
        let url = root.appending(path: rawValue)
        guard
          FileManager.default.createFile(
            atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o755])
        else {
          throw WorkingDirectoryFixtureError.creationFailed(url.path)
        }
        return url.path
      case .symbolicLinkToUnsearchableDirectory:
        let target = try makeDirectory("\(rawValue)-target", mode: 0o000, in: root)
        let link = root.appending(path: rawValue)
        try FileManager.default.createSymbolicLink(
          at: link, withDestinationURL: URL(fileURLWithPath: target))
        return link.path
      case .missingPath: return root.appending(path: rawValue).path
      }
    }
  }
}

private enum WorkingDirectoryFixtureError: Error {
  case creationFailed(String)
}

private func makeDirectory(_ name: String, mode: Int, in root: URL) throws -> String {
  let url = root.appending(path: name)
  try FileManager.default.createDirectory(
    at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: mode])
  return url.path
}

/// fixture は必ずこの木の直下に作る。後始末で権限を戻せる範囲を1階層に限るためで、
/// `0o000` のディレクトリは権限を戻さないと消せない。
private func withTemporaryTree(_ body: (URL) async throws -> Void) async throws {
  let root = URL(fileURLWithPath: NSTemporaryDirectory())
    .appending(path: "awt-session-workdir-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    for name in names {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: root.appending(path: name).path)
    }
    try? FileManager.default.removeItem(at: root)
  }
  try await body(root)
}

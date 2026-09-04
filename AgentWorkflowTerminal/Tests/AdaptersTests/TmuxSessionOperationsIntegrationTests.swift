import Adapters
import Foundation
import TerminalCore
import Testing

private let isTmuxIntegrationEnabled =
  ProcessInfo.processInfo.environment["AWT_TMUX_INTEGRATION"] == "1"

/// 既定サーバに対しては統合テストを書かない。ユーザーが自分で使っている tmux server を
/// 汚すため、`TmuxServer.userDefault` は引数組み立ての単体テストだけで担保する。
@Suite(
  "隔離 tmux server 上の session 操作 (設計書 §3.3 / §4.2 / §4.4)",
  .enabled(if: isTmuxIntegrationEnabled)
)
struct TmuxSessionOperationsIntegrationTests {

  @Test("作成した session は最初の pane に history-limit が、残った window に window-size が効く")
  func createdSessionAppliesProductDefaultsWhereTheyTakeEffect() async throws {
    try await withServer("session-create") { runner, workingDirectory in
      let operations = TmuxSessionOperations(runner: runner)
      let name = try sessionName()
      let globalOptionsBefore = try await globalOptions(runner)

      try await operations.create(session: name, workingDirectory: workingDirectory)

      let paneFormat = "#{history_limit} #{pane_current_path}"
      let panes = try await lines(
        runner, ["list-panes", "-s", "-t", "=\(name.rawValue)", "-F", paneFormat])
      #expect(panes == ["10000 \(workingDirectory)"])

      let windows = try await lines(
        runner, ["list-windows", "-t", "=\(name.rawValue)", "-F", "#{window_id}"])
      #expect(windows.count == 1)
      let window = try #require(windows.first)
      // 継承値なら `window-size* latest` のように `*` が付く。直接設定されたことまで見る。
      #expect(
        try await lines(runner, ["show-options", "-w", "-t", window, "window-size"])
          == ["window-size smallest"])

      #expect(try await globalOptions(runner) == globalOptionsBefore)
    }
  }

  @Test("同名 session があるときは既存 session を変更せずに専用のエラーを返す")
  func duplicateCreateLeavesTheExistingSessionUntouched() async throws {
    try await withServer("session-dup") { runner, workingDirectory in
      let operations = TmuxSessionOperations(runner: runner)
      let name = try sessionName()
      try await operations.create(session: name, workingDirectory: workingDirectory)
      let windowsBefore = try await lines(
        runner, ["list-windows", "-t", "=\(name.rawValue)", "-F", "#{window_id}"])

      await #expect(throws: TmuxSessionOperationError.sessionAlreadyExists(name)) {
        try await operations.create(
          session: name,
          workingDirectory: workingDirectory,
          historyLimit: 99
        )
      }

      #expect(
        try await lines(runner, ["list-windows", "-t", "=\(name.rawValue)", "-F", "#{window_id}"])
          == windowsBefore)
      #expect(
        try await lines(runner, ["show-options", "-t", name.rawValue, "history-limit"])
          == ["history-limit 10000"])
    }
  }

  @Test("存否確認と終了は前方一致の別 session を巻き込まない")
  func existenceAndKillUseExactMatching() async throws {
    try await withServer("session-exact") { runner, workingDirectory in
      let operations = TmuxSessionOperations(runner: runner)
      let name = try sessionName()
      // ユーザーが同じ prefix の session を自分で作っている状況を再現する。
      let sibling = "\(name.rawValue)-extra"
      _ = try await runner.run(arguments: ["new-session", "-d", "-s", sibling])

      #expect(try await operations.exists(session: name) == false)

      try await operations.create(session: name, workingDirectory: workingDirectory)
      #expect(try await operations.exists(session: name))

      try await operations.kill(session: name)

      #expect(try await operations.exists(session: name) == false)
      #expect(try await operations.list().contains(sibling))
      await #expect(throws: TmuxSessionOperationError.sessionNotFound(name)) {
        try await operations.kill(session: name)
      }
    }
  }

  @Test("一覧はアプリが作っていない session も含めてそのまま返す")
  func listReturnsEverySessionName() async throws {
    try await withServer("session-list") { runner, _ in
      let operations = TmuxSessionOperations(runner: runner)
      _ = try await runner.run(arguments: ["new-session", "-d", "-s", "user-plain"])

      let names = try await operations.list()

      #expect(names.contains("user-plain"))
      #expect(names.contains("awt-operations"))
    }
  }

  // MARK: - Helpers

  private func sessionName(
    _ identityPath: String = "/repo/.git/worktrees/feature-a"
  ) throws -> TmuxSessionName {
    TmuxSessionName(identity: try #require(WorktreeIdentity(rawValue: identityPath)))
  }

  private func lines(_ runner: TmuxRunner, _ arguments: [String]) async throws -> [String] {
    try await runner.run(arguments: arguments).stdout.split(separator: "\n").map(String.init)
  }

  /// `-g` / `-wg` を変えていないことの確認用。設計書 §4.2 / §4.4 は、ユーザーが自分で作った
  /// 他の session へ設定を波及させないことを求めている。
  private func globalOptions(_ runner: TmuxRunner) async throws -> [String] {
    try await lines(runner, ["show-options", "-g", "history-limit"])
      + lines(runner, ["show-options", "-wg", "window-size"])
  }

  /// 作業ディレクトリを `/private/tmp` の下に作るのは、tmux が返す `#{pane_current_path}` が
  /// 実体パスである一方、`NSTemporaryDirectory()` は `/var/...` (実体は `/private/var/...`) を
  /// 返し、Foundation の `resolvingSymlinksInPath()` が `/private` を落とすためである。
  private func withServer(
    _ label: String,
    _ body: (TmuxRunner, String) async throws -> Void
  ) async throws {
    let url = URL(fileURLWithPath: "/private/tmp")
      .appending(path: "awt-session-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    try await IsolatedTmuxServer.withServer(socketName: uniqueSocketName(label)) { runner in
      try await body(runner, url.path)
    }
  }
}

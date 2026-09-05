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

  @Test("tmux が加工しかねない文字を含む作業ディレクトリでも、pane はそのディレクトリへ落ちる")
  func createdPaneLandsInDirectoriesWithTmuxMetacharacters() async throws {
    try await withServer("session-meta") { runner, workingDirectory in
      let operations = TmuxSessionOperations(runner: runner)
      let components = ["#{session_name}", "#S", "a##b", "#(echo x)", "#", "wt\\", "mid;dir"]
      for (index, component) in components.enumerated() {
        let directory = "\(workingDirectory)/\(component)"
        try FileManager.default.createDirectory(
          atPath: directory, withIntermediateDirectories: false)
        let name = try sessionName("/repo/.git/worktrees/meta-\(index)")

        try await operations.create(session: name, workingDirectory: directory)

        #expect(
          try await lines(
            runner,
            ["list-panes", "-s", "-t", "=\(name.rawValue)", "-F", "#{pane_current_path}"])
            == [directory])
      }
    }
  }

  /// `TmuxSessionOperations` が `#[` だけを弾く根拠を実サーバで固定する。`create` は tmux へ渡す
  /// 前に弾くので、この経路を `create` 経由では起こせない。
  @Test("`#[` を含むディレクトリは `##` へ二重化すると別の場所へ pane ができる")
  func doublingCannotEscapeAStyleIntroducer() async throws {
    try await withServer("session-style") { runner, workingDirectory in
      let directory = "\(workingDirectory)/#[fg=red]"
      try FileManager.default.createDirectory(
        atPath: directory, withIntermediateDirectories: false)
      let doubled = directory.replacingOccurrences(of: "#", with: "##")

      for (session, argument) in [("awt-style-raw", directory), ("awt-style-esc", doubled)] {
        _ = try await runner.run(
          arguments: ["new-session", "-d", "-s", session, "-c", argument])

        let panePath = try await lines(
          runner, ["list-panes", "-s", "-t", "=\(session)", "-F", "#{pane_current_path}"])
        #expect((panePath == [directory]) == (argument == directory))
      }
    }
  }

  /// `create` が作業ディレクトリを事前に検証する根拠を実サーバで固定する。tmux は chdir できない
  /// ディレクトリを渡されても exit 0 で session を作り、pane を `$HOME` へ落とす。
  @Test("chdir できないディレクトリは、tmux が黙って別の場所へ pane を作る前に弾かれる")
  func rejectsWorkingDirectoryThePaneCannotEnter() async throws {
    try await withServer("session-noexec") { runner, workingDirectory in
      let directory = "\(workingDirectory)/noexec"
      try FileManager.default.createDirectory(
        atPath: directory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o000])
      // 権限を戻さないと `withServer` の後片付けがこのディレクトリを消せない。
      defer {
        try? FileManager.default.setAttributes(
          [.posixPermissions: 0o700], ofItemAtPath: directory)
      }

      _ = try await runner.run(
        arguments: ["new-session", "-d", "-s", "awt-noexec", "-c", directory])
      #expect(
        try await lines(
          runner, ["list-panes", "-s", "-t", "=awt-noexec", "-F", "#{pane_current_path}"])
          == [NSHomeDirectory()])

      let name = try sessionName()
      await #expect(throws: TmuxSessionOperationError.workingDirectoryUnusable(directory)) {
        try await TmuxSessionOperations(runner: runner).create(
          session: name, workingDirectory: directory)
      }
      #expect(try await TmuxSessionOperations(runner: runner).exists(session: name) == false)
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

  // MARK: - server が動いていない状態

  /// `IsolatedTmuxServer` は常に生きた server を用意するので、この経路はそちらでは通らない。
  /// socket ファイルを一度も作っていない状態は、tmux を使ったことがないユーザーの初回状態であり、
  /// tmux 3.4 は `no server running on ` ではなく
  /// `error connecting to <path> (No such file or directory)` を返す。
  @Test("一度も起動していない server では存否が false、一覧が空になる")
  func foldsNeverStartedServerIntoAbsence() async throws {
    let socketName = uniqueSocketName("never-started")
    let operations = TmuxSessionOperations(runner: try neverStartedRunner(socketName))

    #expect(try await operations.exists(session: try sessionName()) == false)
    #expect(try await operations.list().isEmpty)
    #expect(FileManager.default.fileExists(atPath: socketPath(socketName)) == false)
  }

  @Test("一度も起動していない server では session を作らず、server も起動しない")
  func doesNotStartTheServerFromCreate() async throws {
    let socketName = uniqueSocketName("never-created")
    let operations = TmuxSessionOperations(runner: try neverStartedRunner(socketName))

    await #expect(throws: TmuxSessionOperationError.serverNotRunning) {
      try await operations.create(session: try sessionName(), workingDirectory: "/private/tmp")
    }
    #expect(FileManager.default.fileExists(atPath: socketPath(socketName)) == false)
  }

  /// `IsolatedTmuxServer` を使わずに自分で起動・停止するのは、この経路が「server を止めた後の
  /// socket ファイル」を必要とするためで、後片付けを他の仕組みに委ねると socket と server が
  /// 残り得る。
  @Test("起動後に終了して socket が残っている server も存否としては不在に畳む")
  func foldsStoppedServerIntoAbsence() async throws {
    let socketName = uniqueSocketName("stopped")
    let runner = try neverStartedRunner(socketName)
    _ = try await runner.run(
      arguments: ["-f", "/dev/null", "new-session", "-d", "-s", "awt-temporary"])
    _ = try await runner.run(arguments: ["kill-server"])
    defer {
      try? FileManager.default.removeItem(atPath: socketPath(socketName))
    }

    let operations = TmuxSessionOperations(runner: runner)
    let socketRemains = FileManager.default.fileExists(atPath: socketPath(socketName))
    let exists = try await operations.exists(session: sessionName())
    let sessions = try await operations.list()

    #expect(socketRemains)
    #expect(exists == false)
    #expect(sessions.isEmpty)
  }

  // MARK: - 途中失敗の後始末が依存している tmux の挙動

  /// `create` の後始末は「`new-session` の後に失敗したら `$N` 指定で消せる」ことに依存している。
  /// その前提を実サーバで固定する (`create` 自身は不正値を tmux へ渡す前に弾くので、この経路を
  /// `create` 経由では起こせない)。
  @Test("session ID 指定なら、途中失敗で残った session だけを消せる")
  func sessionIDTargetsOnlyTheCreatedSession() async throws {
    try await withServer("session-cleanup") { runner, workingDirectory in
      let created = try await runner.run(
        arguments: [
          "new-session", "-d", "-s", "awt-leftover", "-c", workingDirectory,
          "-P", "-F", "#{session_id}",
        ])
      let sessionID = created.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
      #expect(sessionID.hasPrefix("$"))

      // 設定の途中で失敗させる。history-limit の下限違反は tmux 側のエラー (実測)。
      await #expect(throws: TmuxRunnerError.self) {
        try await runner.run(
          arguments: ["set-option", "-t", sessionID, "history-limit", "-1"])
      }
      #expect(
        try await lines(runner, ["list-sessions", "-F", "#{session_name}"]).sorted()
          == ["awt-leftover", "awt-operations"])

      _ = try await runner.run(arguments: ["kill-session", "-t", sessionID])

      #expect(
        try await lines(runner, ["list-sessions", "-F", "#{session_name}"]) == ["awt-operations"])
    }
  }

  // MARK: - Helpers

  private func sessionName(
    _ identityPath: String = "/repo/.git/worktrees/feature-a"
  ) throws -> TmuxSessionName {
    TmuxSessionName(identity: try #require(WorktreeIdentity(rawValue: identityPath)))
  }

  /// server を起動しない runner。`IsolatedTmuxServer` を使わないので socket は作られない。
  private func neverStartedRunner(_ socketName: String) throws -> TmuxRunner {
    try TmuxRunner(
      socketName: socketName,
      processRunner: FoundationProcessRunner(),
      executableCandidates: [try #require(IsolatedTmuxServer.executableURL())]
    )
  }

  /// `IsolatedTmuxServer` が socket を消すときと同じ規則で組み立てる。
  private func socketPath(_ socketName: String) -> String {
    let parent = ProcessInfo.processInfo.environment["TMUX_TMPDIR"] ?? "/private/tmp"
    return "\(parent)/tmux-\(getuid())/\(socketName)"
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

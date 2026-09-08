import Adapters
import Foundation
import TerminalCore
import Testing

private let isMainPaneIntegrationEnabled =
  ProcessInfo.processInfo.environment["AWT_TMUX_INTEGRATION"] == "1"

@Suite(
  "§12.7 メインpane登録の同一性 (実 tmux)",
  .enabled(if: isMainPaneIntegrationEnabled)
)
struct MainPaneRegistryIntegrationTests {

  /// tmux は `%N` を server の生存中しか一意にしない。server が落ちて session が作り直されると
  /// `%0` から振り直されるため、ID だけの登録は別 pane を指したまま `registered` になる
  /// (Issue #246)。送信経路がこの resolution で分岐するので、実 tmux で「注入されない」ところ
  /// まで見る。
  @Test("kill-server で振り直された同じ pane ID へは送らない")
  func doesNotSendToRecycledPaneIDAfterServerRestart() async throws {
    let socketName = uniqueSocketName("main-pane-recycle")
    try await IsolatedTmuxServer.withServer(socketName: socketName) { runner in
      let workspace = try IntegrationWorkspace()
      defer { workspace.remove() }
      let worktree = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/recycle"))
      let session = TmuxSessionName(identity: worktree)
      let source = TmuxWorktreePaneSource(runner: runner)

      try await makeShellSession(runner, session: session)
      let before = try #require(try await source.panes(of: worktree).first)
      let beforeServer = try #require(try await source.serverProcessID())
      print(
        "[measure] before restart: \(before.id.rawValue) pane_pid=\(before.processID) "
          + "server=\(beforeServer)")

      var registry = MainPaneRegistry()
      registry.register(
        MainPaneRegistration(before, serverProcessID: beforeServer), for: worktree)
      let beforeResolution = registry.resolve(
        for: worktree, panes: try await source.panes(of: worktree),
        serverProcessID: beforeServer)
      guard case .registered = beforeResolution else {
        Issue.record("再起動前は登録先が生きているはずが \(beforeResolution)")
        return
      }

      try await restartServer(runner, session: session)
      let after = try #require(try await source.panes(of: worktree).first)
      let afterServer = try #require(try await source.serverProcessID())
      print(
        "[measure] after  restart: \(after.id.rawValue) pane_pid=\(after.processID) "
          + "server=\(afterServer)")
      // ID が振り直されていなければ、この計測は #246 の条件を再現できていない。
      #expect(after.id == before.id)
      #expect(afterServer != beforeServer)

      // 対照: 同じ経路で明示的に撃つと届く。これを先に見ておかないと、下の「届かない」は
      // 注入が壊れていても probe が空でも target が違っても真になる。
      let control = IntegrationExecutionProbe(workspace: workspace, name: "control")
      try await TmuxTextInjection(runner: runner).inject(control.text, into: after.id)
      try await waitUntil("対照の注入が pane の画面に出る") {
        try await capturePane(runner, pane: after.id).contains(control.token)
      }
      print("[measure] control token in pane? true")

      let guarded = IntegrationExecutionProbe(workspace: workspace, name: "guarded")
      let resolution = registry.resolve(
        for: worktree, panes: try await source.panes(of: worktree), serverProcessID: afterServer)
      print("[measure] resolution=\(resolution.measurementLabel)")
      // 送信経路の分岐そのもの (`DiffViewerModel.requestSend`)。`registered` のときだけ注入する。
      if case .registered(let registration, _) = resolution {
        _ = await injectWithIdentity(guarded.text, registration: registration, runner: runner)
      }

      #expect(resolution.absence == .paneReplaced(before.id))
      try await Task.sleep(for: .seconds(1))
      // 貼り付けは行編集バッファに入るだけで実行までは行かない場合があるため、届いたかどうかは
      // 実行痕跡ではなく画面で見る (§9.2.1 制約1)。
      let screen = try await capturePane(runner, pane: after.id)
      print(
        "[measure] guarded token in pane? \(screen.contains(guarded.token)) "
          + "/ control token still there? \(screen.contains(control.token))")
      #expect(!screen.contains(guarded.token))
      #expect(screen.contains(control.token))
      #expect(!guarded.didExecute)
    }
  }

  @Test("pane_pid まで一致しても server が入れ替わっていれば送らない")
  func doesNotSendWhenOnlyServerIdentityDiffers() async throws {
    let socketName = uniqueSocketName("main-pane-server")
    try await IsolatedTmuxServer.withServer(socketName: socketName) { runner in
      let worktree = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/server-id"))
      let session = TmuxSessionName(identity: worktree)
      let source = TmuxWorktreePaneSource(runner: runner)
      try await makeShellSession(runner, session: session)
      let pane = try #require(try await source.panes(of: worktree).first)
      let server = try #require(try await source.serverProcessID())

      var registry = MainPaneRegistry()
      // `%N` と `pane_pid` が両方一致し、server だけが違う状況を直接作る。PID 空間を1周させて
      // 自然発生を待つ代わりに、登録側の server PID をずらして同じ組を再現する。
      registry.register(
        MainPaneRegistration(pane, serverProcessID: server &+ 1), for: worktree)
      let resolution = registry.resolve(
        for: worktree, panes: [pane], serverProcessID: server)
      print(
        "[measure] same pane=\(pane.id.rawValue) same pane_pid=\(pane.processID) "
          + "server \(server &+ 1) -> \(server): \(resolution.measurementLabel)")

      #expect(resolution.absence == .paneReplaced(pane.id))
    }
  }

  /// picker は人が操作するまで開いたままなので、候補を見せてから撃つまでに server が
  /// 入れ替わり得る。同一性を見ない経路 (修正前の `choose` → `send`) との対照を取る。
  @Test("picker で選んだ後に server が入れ替わっても、同一性つきの注入は止まる")
  func doesNotInjectWhenTheChosenPaneWasReplaced() async throws {
    let socketName = uniqueSocketName("main-pane-toctou")
    try await IsolatedTmuxServer.withServer(socketName: socketName) { runner in
      let workspace = try IntegrationWorkspace()
      defer { workspace.remove() }
      let worktree = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/toctou"))
      let session = TmuxSessionName(identity: worktree)
      let source = TmuxWorktreePaneSource(runner: runner)
      try await makeShellSession(runner, session: session)
      // picker が候補を並べた時点の観測。ユーザーが選ぶまでこの値が握られる。
      let chosen = try #require(try await source.panes(of: worktree).first)
      let chosenServer = try #require(try await source.serverProcessID())
      let registration = MainPaneRegistration(chosen, serverProcessID: chosenServer)

      // sheet が開いている間に server が落ちて作り直された。
      try await restartServer(runner, session: session)
      let now = try #require(try await source.panes(of: worktree).first)
      #expect(now.id == registration.pane)

      // 対照: 修正前の経路は登録の `PaneID` へそのまま撃つ。
      let control = IntegrationExecutionProbe(workspace: workspace, name: "toctou-control")
      try await TmuxTextInjection(runner: runner).inject(control.text, into: registration.pane)
      try await waitUntil("対照の注入が pane の画面に出る") {
        try await capturePane(runner, pane: now.id).contains(control.token)
      }

      let guarded = IntegrationExecutionProbe(workspace: workspace, name: "toctou-guarded")
      let failure = await injectWithIdentity(
        guarded.text, registration: registration, runner: runner)

      try await Task.sleep(for: .seconds(1))
      let screen = try await capturePane(runner, pane: now.id)
      print(
        "[measure] picker が握った登録: \(registration.pane.rawValue) "
          + "pane_pid=\(registration.processID) server=\(registration.serverProcessID)")
      print("[measure] 同一性を見ない注入 (修正前) が届いた? \(screen.contains(control.token))")
      print(
        "[measure] 同一性つき注入 (修正後) = \(String(describing: failure)) "
          + "/ 届いた? \(screen.contains(guarded.token))")
      #expect(screen.contains(control.token))
      #expect(failure == .paneIdentityMismatch(registration.pane))
      #expect(!screen.contains(guarded.token))
    }
  }

  /// M1(a) の対照。**判定と paste の間**に server が入れ替わる窓が、クライアント側で先に
  /// 確認する形では実際に踏めること、1コマンドに載せた形では踏めないことを見る。
  @Test("同一性の確認と paste の間に server が入れ替わっても、1コマンドなら送らない")
  func closesTheWindowBetweenTheCheckAndThePaste() async throws {
    let socketName = uniqueSocketName("main-pane-window")
    try await IsolatedTmuxServer.withServer(socketName: socketName) { runner in
      let workspace = try IntegrationWorkspace()
      defer { workspace.remove() }
      let worktree = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/window"))
      let session = TmuxSessionName(identity: worktree)
      let source = TmuxWorktreePaneSource(runner: runner)
      try await makeShellSession(runner, session: session)
      let pane = try #require(try await source.panes(of: worktree).first)
      let server = try #require(try await source.serverProcessID())
      let registration = MainPaneRegistration(pane, serverProcessID: server)

      // 修正前の形: 先に照合して `.registered` を得る。
      var registry = MainPaneRegistry()
      registry.register(registration, for: worktree)
      let checked = registry.resolve(
        for: worktree, panes: try await source.panes(of: worktree), serverProcessID: server)
      #expect(checked.absence == nil)

      // 照合と注入の**間**に server が入れ替わる。これが残っていた窓そのもの。
      try await restartServer(runner, session: session)
      let now = try #require(try await source.panes(of: worktree).first)
      #expect(now.id == registration.pane)

      let stale = IntegrationExecutionProbe(workspace: workspace, name: "window-stale")
      try await TmuxTextInjection(runner: runner).inject(stale.text, into: registration.pane)
      try await waitUntil("照合済みとして撃った本文が画面に出る") {
        try await capturePane(runner, pane: now.id).contains(stale.token)
      }

      let guarded = IntegrationExecutionProbe(workspace: workspace, name: "window-guarded")
      let failure = await injectWithIdentity(
        guarded.text, registration: registration, runner: runner)

      try await Task.sleep(for: .seconds(1))
      let screen = try await capturePane(runner, pane: now.id)
      print(
        "[measure] 照合後に server 入れ替え: 照合済みとして撃つと届く? "
          + "\(screen.contains(stale.token))")
      print(
        "[measure] 同じ登録を1コマンドで撃つと = \(String(describing: failure)) "
          + "/ 届いた? \(screen.contains(guarded.token))")
      #expect(screen.contains(stale.token))
      #expect(failure == .paneIdentityMismatch(registration.pane))
      #expect(!screen.contains(guarded.token))
    }
  }

  /// 拒否された注入が、**本文を抱えた buffer を tmux server に残さない**こと。
  /// gate 単体で見ると同一性不一致の枝は buffer を消さない (実測: 拒否のたびに
  /// `awt-inject-<UUID>` が本文ごと残る) ので、`inject` の無条件 `deleteBuffer` が
  /// 効いていることをここで固定する。copy-mode / 入力無効の既存テストはこの枝を通らない。
  @Test("同一性不一致で拒否しても、本文を抱えた buffer を残さない")
  func leavesNoBufferBehindWhenTheIdentityDoesNotMatch() async throws {
    let socketName = uniqueSocketName("main-pane-buffers")
    try await IsolatedTmuxServer.withServer(socketName: socketName) { runner in
      let worktree = try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/buffers"))
      let session = TmuxSessionName(identity: worktree)
      let source = TmuxWorktreePaneSource(runner: runner)
      try await makeShellSession(runner, session: session)
      let pane = try #require(try await source.panes(of: worktree).first)
      let server = try #require(try await source.serverProcessID())
      // ユーザーの buffer が巻き添えで消えないことも同時に見る。
      _ = try await runner.run(arguments: ["set-buffer", "-b", "user-named", "USER NAMED"])
      let before = try await runner.run(arguments: ["list-buffers"]).stdout

      // server PID だけをずらして必ず不一致にする。
      let stale = MainPaneRegistration(pane, serverProcessID: server &+ 1)
      let secret = "AWT_SECRET_\(UInt32.random(in: 0..<1_000_000))"
      let failure = await injectWithIdentity(secret + "\n", registration: stale, runner: runner)

      let after = try await runner.run(arguments: ["list-buffers"]).stdout
      print("[measure] 拒否=\(String(describing: failure))")
      print("[measure] list-buffers 変化なし? \(after == before) / 本文の残存? \(after.contains(secret))")
      #expect(failure == .paneIdentityMismatch(stale.pane))
      #expect(after == before)
      #expect(before.contains("user-named:"))
    }
  }

  /// 注入したテキストが実行され得る pane を作る。macOS 標準の bash 3.2 ではなく zsh を使うのは
  /// `TmuxTextInjection` の統合テストと同じ理由 (bracketed paste の有無で結果が変わるため)。
  private static func shellSessionArguments(session: TmuxSessionName) -> [String] {
    [
      "new-session", "-d", "-s", session.rawValue, "-x", "200", "-y", "50",
      "-e", "PS1=AWT_SHELL_READY> ", "/bin/zsh", "-f", "-i",
    ]
  }

  private func makeShellSession(_ runner: TmuxRunner, session: TmuxSessionName) async throws {
    _ = try await runner.run(arguments: Self.shellSessionArguments(session: session))
    try await waitForShellPrompt(runner, session: session)
  }

  /// prompt が出ていれば zle が動いている = 受け側が bracketed paste を立てている。
  private func waitForShellPrompt(_ runner: TmuxRunner, session: TmuxSessionName) async throws {
    try await waitUntil("shell の prompt 表示") {
      let panes = try await runner.run(
        arguments: ["list-panes", "-s", "-t", "=\(session.rawValue)", "-F", "#{pane_id}"])
      guard let first = panes.stdout.split(separator: "\n").first else { return false }
      return try await capturePane(runner, pane: PaneID(rawValue: String(first)))
        .contains("AWT_SHELL_READY>")
    }
  }

  private func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(20),
    condition: () async throws -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if try await condition() { return }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw IntegrationTimeout(description: description)
  }

  /// server ごと作り直す。`%N` は server ごとに 0 から振り直されるので、同じ ID を再現するには
  /// session の作成順も揃える。アプリでも Project Root の session (§12) が worktree session
  /// より先に居る。作り直した server がユーザーの `~/.tmux.conf` を読んでいないことも見る。
  private func restartServer(_ runner: TmuxRunner, session: TmuxSessionName) async throws {
    try await IsolatedTmuxServer.restartServer(
      runner,
      creatingSessions: [
        ["new-session", "-d", "-s", "awt-operations", "sleep 300"],
        Self.shellSessionArguments(session: session),
      ])
    try await waitForShellPrompt(runner, session: session)
    let options = try await globalOptions(runner)
    print("[measure] recreated server options: \(options)")
    #expect(options.contains("prefix C-b"))
  }

  private func globalOptions(_ runner: TmuxRunner) async throws -> [String] {
    let output = try await runner.run(arguments: ["show-options", "-g"])
    return output.stdout.split(separator: "\n").map(String.init).filter {
      $0.hasPrefix("prefix ") || $0.hasPrefix("status-position ")
        || $0.hasPrefix("history-limit ")
    }
  }

  /// `MainPaneCoordinator.inject` と同じ経路。同一性の照合は `paste-buffer` と同じ tmux
  /// コマンドの中で行われるので、判定と paste の間に server が入れ替わる窓は無い。
  private func injectWithIdentity(
    _ text: String,
    registration: MainPaneRegistration,
    runner: TmuxRunner
  ) async -> TmuxTextInjectionError? {
    do {
      try await TmuxTextInjection(runner: runner).inject(
        text,
        into: TmuxPaneIdentity(
          pane: registration.pane,
          paneProcessID: registration.processID,
          serverProcessID: registration.serverProcessID))
      return nil
    } catch {
      return error
    }
  }

  private func capturePane(_ runner: TmuxRunner, pane: PaneID) async throws -> String {
    try await runner.run(arguments: ["capture-pane", "-p", "-t", pane.rawValue]).stdout
  }
}

extension MainPaneResolution {
  /// 計測ログ用。候補一覧まで出すと読めないので、分岐と登録先だけを短く出す。
  fileprivate var measurementLabel: String {
    switch self {
    case .unregistered: "unregistered"
    case .registered(let registration, _):
      "registered(\(registration.pane.rawValue) pane_pid=\(registration.processID) "
        + "server=\(registration.serverProcessID))"
    case .registeredPaneMissing(let registration, _, _):
      "registeredPaneMissing(\(registration.pane.rawValue) pane_pid=\(registration.processID) "
        + "server=\(registration.serverProcessID))"
    }
  }
}

private struct IntegrationTimeout: Error, CustomStringConvertible {
  let description: String
}

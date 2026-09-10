import Adapters
import Foundation
import TerminalCore
import Testing

@testable import AgentWorkflowTerminalApp

/// 連打で同じコメントが2回貼られないこと (Issue #276)。
///
/// 注入の**回数**は偽の `ProcessRunning` が数える。`MainPaneCoordinator` は `TmuxRunner` が持つ
/// この protocol seam から丸ごと駆動できるので、本番コードへテスト用の口を足していない。
/// 中断点の保持も同じ seam で行う: 偽の runner が任意の tmux サブコマンドの完了を保留するため、
/// `resolve` の中断中に2度目の要求を届けられる。
@Suite("Diff コメント送信の直列化 (Issue #276)", .serialized)
@MainActor
struct DiffCommentSendSerializationTests {

  /// 窓1: 1度目が `resolve` で中断している間に2度目の `requestSend` が届く。
  /// 2度目の注入は1度目の注入が**終わった後**に着地するので、`send` 側の `isSending` では
  /// 止まらない。
  @Test("resolve の中断中に届いた2度目の requestSend は捨てられる")
  func dropsSecondRequestArrivingDuringResolve() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.cleanUp() }
    let runner = fixture.processRunner

    // `resolve` は list-panes → display-message の2回撃つ。後者は pane 一覧のキャッシュを
    // 経由しないので、要求ごとに1つずつ保留できる。
    await runner.hold("display-message")
    let first = Task { await fixture.requestSend() }
    try await runner.expectHeldCalls(1, of: "display-message")

    let second = Task { await fixture.requestSend() }
    await Fixture.letPendingTasksRun()

    // 1度目を注入の完了まで走らせきってから2度目を進める (窓2 と同じ着地順)。
    await runner.resumeHeldCall(of: "display-message")
    await first.value
    await runner.resume("display-message")
    await second.value

    #expect(await runner.injectionCount == 1)
    #expect(fixture.model.isSending == false)
    #expect(fixture.sentComments == 1)
  }

  /// 窓2: 2度目が `send` へ直接届く経路 (pane 選択 sheet の確定)。1度目が `resolve` で
  /// 中断している間は `isSending` が false なので、`send` の guard は素通りする。
  @Test("resolve の中断中に届いた2度目の send (pane 選択の確定) は捨てられる")
  func dropsSecondDirectSendArrivingDuringResolve() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.cleanUp() }
    let runner = fixture.processRunner

    await runner.hold("display-message")
    let first = Task { await fixture.requestSend() }
    try await runner.expectHeldCalls(1, of: "display-message")

    let second = Task { await fixture.send() }
    await Fixture.letPendingTasksRun()

    await runner.resume("display-message")
    await first.value
    await second.value

    #expect(await runner.injectionCount == 1)
    #expect(fixture.model.isSending == false)
    #expect(fixture.sentComments == 1)
  }

  /// 直列化が「捨てる」だけで終わらないこと。送信が終われば次の送信は通る。
  @Test("送信が終わった後の2度目の要求は通る")
  func allowsSendAfterPreviousSendCompleted() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.cleanUp() }

    await fixture.requestSend()
    await fixture.requestSend()

    #expect(await fixture.processRunner.injectionCount == 2)
  }
}

extension DiffCommentSendSerializationTests {
  /// 送信を1回行える状態まで組み立てた `DiffViewerModel` と、その注入先。
  ///
  /// コメントは `addComment` からしか作れず、そこには snapshot が必要なので、git は実物を
  /// 使う (`DiffViewerModel` の git 呼び出しは `FoundationProcessRunner` 固定)。tmux 側だけを
  /// 偽の `ProcessRunning` に差し替える。
  @MainActor
  struct Fixture {
    let model: DiffViewerModel
    let coordinator: MainPaneCoordinator
    let processRunner: GatedTmuxProcessRunner
    let worktree: WorktreeIdentity
    let comment: DiffReviewCommentID
    let registration: MainPaneRegistration
    let agentPaneStates: [PaneAgentState]
    private let repositoryRoot: URL

    static let pane = PaneID(rawValue: "%1")
    static let panePID: Int32 = 4242
    static let serverPID: Int32 = 9999

    static func make() async throws -> Self {
      let repositoryRoot = try makeRepository()
      // 安定 ID は git の管理ディレクトリの絶対パス (§3.5)。session 名はここから決まる。
      let worktree = try #require(
        WorktreeIdentity(rawValue: repositoryRoot.appendingPathComponent(".git").path))
      let processRunner = GatedTmuxProcessRunner(
        sessionName: TmuxSessionName(identity: worktree).rawValue,
        pane: pane, panePID: panePID, serverPID: serverPID)
      let runner = try TmuxRunner(
        server: .userDefault, processRunner: processRunner,
        executableCandidates: [URL(fileURLWithPath: "/bin/echo")])
      let coordinator = MainPaneCoordinator(runner: runner)
      let registration = MainPaneRegistration(
        pane: pane, processID: panePID, serverProcessID: serverPID)
      coordinator.register(registration, for: worktree)

      let model = DiffViewerModel(worktreeRoot: repositoryRoot)
      model.kind = .commit
      await model.loadContext()
      await model.openSnapshot()
      model.selectLine(1, side: .new)
      model.commentDraft = "二重貼り付けの回帰テスト"
      model.addComment()
      let comment = try #require(model.currentSnapshotComments.first).id

      return Self(
        model: model, coordinator: coordinator, processRunner: processRunner, worktree: worktree,
        comment: comment, registration: registration,
        agentPaneStates: [PaneAgentState(id: pane, state: .completed, lastUpdatedAt: Date())],
        repositoryRoot: repositoryRoot)
    }

    /// 送信済みとして印が付いたコメントの数。二重送信では印は1つのままなので、注入回数と
    /// 合わせて見る (印だけを見ても二重貼り付けは見えない)。
    var sentComments: Int {
      model.currentSnapshotComments.count { $0.sentAt != nil }
    }

    func requestSend() async {
      await model.requestSend(
        .single(comment), worktree: worktree, mainPane: coordinator,
        agentPaneStates: agentPaneStates)
    }

    func send() async {
      await model.send(
        .single(comment), to: registration, worktree: worktree, mainPane: coordinator,
        agentPaneStates: agentPaneStates)
    }

    func cleanUp() {
      try? FileManager.default.removeItem(at: repositoryRoot)
    }

    /// 直前に作った `Task` が MainActor 上で走り出すまで場所を譲る。回数は「走り出したか」を
    /// 直接観測できない範囲での上限で、これで足りることは変異テスト (修正を戻すと落ちる) で
    /// 確かめている。
    static func letPendingTasksRun() async {
      for _ in 0..<64 { await Task.yield() }
    }

    private static func makeRepository() throws -> URL {
      let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("awt-diff-send-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      try git(["init", "-q", "-b", "main"], in: root)
      try write("base\n", to: root.appendingPathComponent("base.txt"))
      try git(["add", "."], in: root)
      try git(["commit", "-q", "-m", "base"], in: root)
      // HEAD の diff を「追加された1行のファイル」にして、new 側 1 行目が必ず在る形にする。
      try write("added\n", to: root.appendingPathComponent("added.txt"))
      try git(["add", "."], in: root)
      try git(["commit", "-q", "-m", "add"], in: root)
      return root
    }

    private static func write(_ contents: String, to url: URL) throws {
      try Data(contents.utf8).write(to: url, options: .atomic)
    }

    private static func git(_ arguments: [String], in root: URL) throws {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
      // ユーザーの ~/.gitconfig に identity が無くても commit できるようにする。
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
      #expect(process.terminationStatus == 0, "git \(arguments.joined(separator: " "))")
    }
  }
}

/// tmux を起動しない `ProcessRunning`。呼ばれたサブコマンドを数え、指定したサブコマンドの
/// 完了をテストが解放するまで保留する。
actor GatedTmuxProcessRunner: ProcessRunning {
  private let sessionName: String
  private let pane: PaneID
  private let panePID: Int32
  private let serverPID: Int32

  private var invocations: [[String]] = []
  private var heldCommands: Set<String> = []
  private var held: [String: [CheckedContinuation<Void, Never>]] = [:]

  init(sessionName: String, pane: PaneID, panePID: Int32, serverPID: Int32) {
    self.sessionName = sessionName
    self.pane = pane
    self.panePID = panePID
    self.serverPID = serverPID
  }

  /// 注入1回につき `load-buffer` はちょうど1回撃たれる (`TmuxTextInjection.send`)。
  var injectionCount: Int {
    invocations.count { $0.contains("load-buffer") }
  }

  func hold(_ command: String) {
    heldCommands.insert(command)
  }

  /// 保留中の呼び出しのうち先頭の1つだけを解放する。以後の同じサブコマンドは保留したままにする。
  func resumeHeldCall(of command: String) {
    guard var pending = held[command], !pending.isEmpty else { return }
    let first = pending.removeFirst()
    held[command] = pending
    first.resume()
  }

  /// 保留を解除し、待っている呼び出しをすべて解放する。
  func resume(_ command: String) {
    heldCommands.remove(command)
    let pending = held.removeValue(forKey: command) ?? []
    for continuation in pending { continuation.resume() }
  }

  /// 期待した数の呼び出しが保留に入るまで待つ。入らないまま上限に達したら失敗させる
  /// (テストを無限に待たせない)。
  func expectHeldCalls(_ count: Int, of command: String) async throws {
    for _ in 0..<10_000 {
      if held[command]?.count == count { return }
      await Task.yield()
    }
    Issue.record("\(command) の保留が \(count) 件に達しませんでした")
    throw CancellationError()
  }

  func run(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    timeout: Duration,
    outputLimit: Int
  ) async throws(ProcessRunnerError) -> ProcessRunResult {
    invocations.append(arguments)
    // global option (`-u`) の後に来る最初の非オプションがサブコマンド。
    let command = arguments.first { !$0.hasPrefix("-") } ?? ""
    if heldCommands.contains(command) {
      await withCheckedContinuation { continuation in
        held[command, default: []].append(continuation)
      }
    }
    return ProcessRunResult(exitCode: 0, stdout: stdout(for: command), stderr: "")
  }

  private func stdout(for command: String) -> String {
    switch command {
    case "list-panes": paneListLine + "\n"
    case "display-message": "\(serverPID)\n"
    default: ""
    }
  }

  /// `TmuxListPanes.format` と同じ 14 フィールドを Unit Separator で並べた1行。
  private var paneListLine: String {
    [
      pane.rawValue, sessionName, "0", "@0", "0", "\(panePID)", "1", "zsh", "0", "", "",
      "/dev/ttys001", "/tmp", "title",
    ].joined(separator: "\u{1F}")
  }
}

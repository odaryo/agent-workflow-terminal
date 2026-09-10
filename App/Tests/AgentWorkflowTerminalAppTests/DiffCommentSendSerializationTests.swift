import Adapters
import Foundation
import TerminalCore
import Testing
import os

@testable import AgentWorkflowTerminalApp

/// 連打で同じコメントが2回貼られないこと (Issue #276)。
///
/// 注入の**回数**は偽の `ProcessRunning` が数える。`MainPaneCoordinator` は `TmuxRunner` が持つ
/// この protocol seam から丸ごと駆動できるので、本番コードへテスト用の口を足していない。
/// 中断点の保持も同じ seam で行う: 偽の runner が任意の tmux サブコマンドの完了を保留するため、
/// 送信の途中で2度目の要求を届けられる。
///
/// coalescing の閾値だけは時刻源を差し替えて動かす。実時間を待つと CI で不安定になるため。
@Suite("Diff コメント送信の直列化と coalescing (Issue #276)", .serialized)
@MainActor
struct DiffCommentSendSerializationTests {

  /// 1度目が `resolve` で中断している間に、`requestSend` の入口へ届いた2度目。
  @Test("進行中の送信があるとき requestSend の入口へ届いた要求は捨てられる")
  func dropsSecondRequestArrivingWhileSendInProgress() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.cleanUp() }
    let runner = fixture.processRunner

    // `resolve` は list-panes → display-message の2回撃つ。後者は pane 一覧のキャッシュを
    // 経由しないので、要求ごとに1つずつ保留できる。
    await runner.hold("display-message")
    let first = SendTask { await fixture.requestSend() }
    try await runner.expectHeldCalls(1, of: "display-message")

    let second = SendTask { await fixture.requestSend() }
    await Fixture.letPendingTasksRun()

    await runner.resume("display-message")
    try await first.expectFinished("1度目の requestSend")
    try await second.expectFinished("2度目の requestSend")

    #expect(await runner.injectionCount == 1)
    #expect(fixture.model.isSending == false)
    #expect(fixture.sentComments == 1)
  }

  /// 同じことを、`requestSend` を経ない独立の入口 (pane 選択 sheet の確定 = `send`) で測る。
  @Test("進行中の送信があるとき send の入口 (pane 選択の確定) へ届いた要求は捨てられる")
  func dropsSecondDirectSendArrivingWhileSendInProgress() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.cleanUp() }
    let runner = fixture.processRunner

    await runner.hold("display-message")
    let first = SendTask { await fixture.requestSend() }
    try await runner.expectHeldCalls(1, of: "display-message")

    let second = SendTask { await fixture.send() }
    await Fixture.letPendingTasksRun()

    await runner.resume("display-message")
    try await first.expectFinished("1度目の requestSend")
    try await second.expectFinished("2度目の send")

    #expect(await runner.injectionCount == 1)
    #expect(fixture.model.isSending == false)
    #expect(fixture.sentComments == 1)
  }

  /// T1: 1度目が**完了した後**に閾値内で届いた同一要求 (= 人のダブルクリック) は捨てられる。
  @Test("送信が完了した後、閾値内に届いた同一要求は捨てられる")
  func dropsIdenticalRequestWithinCoalescingWindow() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.cleanUp() }

    await fixture.requestSend()
    // ダブルクリックの間隔。macOS の既定閾値 0.8 秒より内側。
    fixture.timeSource.advance(by: .milliseconds(200))
    await fixture.requestSend()

    #expect(await fixture.processRunner.injectionCount == 1)
    #expect(fixture.sentComments == 1)
  }

  /// T2: 閾値を超えてからの同一要求は通る。「常に1回しか注入しない実装」を落とす陽性対照。
  @Test("閾値を超えてから届いた同一要求は通る")
  func allowsIdenticalRequestAfterCoalescingWindow() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.cleanUp() }

    await fixture.requestSend()
    fixture.timeSource.advance(by: DiffCommentSendCoalescer.window + .milliseconds(1))
    await fixture.requestSend()

    #expect(await fixture.processRunner.injectionCount == 2)
  }

  /// T2b: 閾値そのものが長すぎないこと。T2 は `window` を参照して相対的に跨ぐので、定数が
  /// 1 分に伸びても緑のまま通る (窓を上から挟めない)。要求「意図的な再送を妨げない」は
  /// 窓の長さに直接かかっているので、実時間の絶対値で挟んでおく。
  @Test("2 秒おいた同一要求は通る (閾値が長すぎないことの上限)")
  func allowsIdenticalRequestAfterTwoSeconds() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.cleanUp() }

    await fixture.requestSend()
    fixture.timeSource.advance(by: .seconds(2))
    await fixture.requestSend()

    #expect(await fixture.processRunner.injectionCount == 2)
  }

  /// T3: 注入が失敗した直後の同一要求は通る。記録するのが成功時だけであることの回帰。
  @Test("注入が失敗した直後の同一要求は通る")
  func allowsIdenticalRequestRightAfterFailedInjection() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.cleanUp() }

    await fixture.processRunner.failNextInjection()
    await fixture.requestSend()
    #expect(fixture.model.commentError != nil)
    #expect(fixture.sentComments == 0)

    // 時計を進めずに押し直す。失敗を記録していれば、この再試行が捨てられる。
    await fixture.requestSend()

    #expect(await fixture.processRunner.injectionCount == 2)
    #expect(fixture.sentComments == 1)
  }

  /// T4: 中身の違う要求は閾値内でも通る。
  @Test("別のコメントの要求は閾値内でも通る")
  func allowsDifferentRequestWithinCoalescingWindow() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.cleanUp() }

    await fixture.requestSend(.single(fixture.comment))
    await fixture.requestSend(.single(fixture.otherComment))

    #expect(await fixture.processRunner.injectionCount == 2)
  }

  /// 同一判定が `.batch` の並び順に依存しないこと。合成 `==` は配列比較なのですり抜ける。
  @Test("batch は並び順が違っても同一要求として捨てられる")
  func dropsReorderedBatchWithinCoalescingWindow() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.cleanUp() }

    await fixture.requestSend(.batch([fixture.comment, fixture.otherComment]))
    await fixture.requestSend(.batch([fixture.otherComment, fixture.comment]))

    #expect(await fixture.processRunner.injectionCount == 1)
    #expect(fixture.sentComments == 2)
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
    let timeSource: TestTimeSource
    let worktree: WorktreeIdentity
    let comment: DiffReviewCommentID
    let otherComment: DiffReviewCommentID
    let registration: MainPaneRegistration
    let agentPaneStates: [PaneAgentState]
    private let repositoryRoot: URL

    static let pane = PaneID(rawValue: "%1")
    static let panePID: Int32 = 4242
    static let serverPID: Int32 = 9999

    static func make() async throws -> Self {
      let repositoryRoot = try makeRepository()
      do {
        return try await make(in: repositoryRoot)
      } catch {
        // 組み立ての途中で落ちたときも temp リポジトリを残さない (呼び出し側の
        // `defer { fixture.cleanUp() }` は make が返らないと登録されない)。
        try? FileManager.default.removeItem(at: repositoryRoot)
        throw error
      }
    }

    private static func make(in repositoryRoot: URL) async throws -> Self {
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

      let timeSource = TestTimeSource()
      let model = DiffViewerModel(worktreeRoot: repositoryRoot, timeSource: timeSource)
      model.kind = .commit
      await model.loadContext()
      await model.openSnapshot()
      let comments = try addComments(to: model)

      return Self(
        model: model, coordinator: coordinator, processRunner: processRunner,
        timeSource: timeSource, worktree: worktree,
        comment: comments.first, otherComment: comments.second, registration: registration,
        agentPaneStates: [PaneAgentState(id: pane, state: .completed, lastUpdatedAt: Date())],
        repositoryRoot: repositoryRoot)
    }

    /// HEAD の diff で追加された2行に、それぞれ1件ずつコメントを付ける。
    private static func addComments(
      to model: DiffViewerModel
    ) throws -> (first: DiffReviewCommentID, second: DiffReviewCommentID) {
      for line in [1, 2] {
        model.selectLine(line, side: .new)
        model.commentDraft = "二重貼り付けの回帰テスト \(line)"
        model.addComment()
      }
      let ids = model.currentSnapshotComments.map(\.id)
      try #require(ids.count == 2)
      return (ids[0], ids[1])
    }

    /// 送信済みとして印が付いたコメントの数。二重送信では印は増えないので、注入回数と
    /// 合わせて見る (印だけを見ても二重貼り付けは見えない)。
    var sentComments: Int {
      model.currentSnapshotComments.count { $0.sentAt != nil }
    }

    func requestSend(_ pending: DiffViewerModel.PendingSend? = nil) async {
      await model.requestSend(
        pending ?? .single(comment), worktree: worktree, mainPane: coordinator,
        agentPaneStates: agentPaneStates)
    }

    func send(_ pending: DiffViewerModel.PendingSend? = nil) async {
      await model.send(
        pending ?? .single(comment), to: registration, worktree: worktree, mainPane: coordinator,
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
      do {
        try git(["init", "-q", "-b", "main"], in: root)
        try write("base\n", to: root.appendingPathComponent("base.txt"))
        try git(["add", "."], in: root)
        try git(["commit", "-q", "-m", "base"], in: root)
        // HEAD の diff を「追加された2行のファイル」にして、new 側 1・2 行目を必ず在る形にする。
        try write("added\nsecond\n", to: root.appendingPathComponent("added.txt"))
        try git(["add", "."], in: root)
        try git(["commit", "-q", "-m", "add"], in: root)
      } catch {
        try? FileManager.default.removeItem(at: root)
        throw error
      }
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

/// 送信を走らせる `Task` と、その完了の**上限付き**の待ち合わせ。
///
/// `await task.value` を直接待たないのは、偽 runner が保留したまま解放されないコマンドを
/// 撃たれた場合にテストが失敗ではなく**ハング**するため (Swift Testing に per-test の既定
/// timeout は無い)。上限は実時間ではなく yield 回数で置く。
@MainActor
final class SendTask {
  private var isFinished = false
  private var task: Task<Void, Never>?

  init(_ body: @escaping @MainActor () async -> Void) {
    task = Task { [self] in
      await body()
      isFinished = true
    }
  }

  func expectFinished(_ label: String) async throws {
    for _ in 0..<100_000 {
      if isFinished { return }
      await Task.yield()
    }
    Issue.record("\(label) が完了しませんでした")
    throw CancellationError()
  }
}

/// 閾値の経過を実時間を待たずに動かすための時刻源。
struct TestTimeSource: ContinuousTimeSource {
  private let state = OSAllocatedUnfairLock(initialState: ContinuousClock().now)

  var now: ContinuousClock.Instant { state.withLock { $0 } }

  func advance(by duration: Duration) {
    state.withLock { $0 = $0.advanced(by: duration) }
  }

  /// coalescing は待たずに捨てるだけなので、呼ばれたら想定外。
  func sleep(until deadline: ContinuousClock.Instant) async throws {
    Issue.record("coalescing は sleep しない")
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
  private var failingInjections = 0

  init(sessionName: String, pane: PaneID, panePID: Int32, serverPID: Int32) {
    self.sessionName = sessionName
    self.pane = pane
    self.panePID = panePID
    self.serverPID = serverPID
  }

  /// 注入1回につき `load-buffer` はちょうど1回撃たれる (`TmuxTextInjection.send`)。
  /// 失敗させた注入も1回として数える。
  var injectionCount: Int {
    invocations.count { $0.contains("load-buffer") }
  }

  /// 次の注入を「tmux server が居ない」で失敗させる。1バイトも届かない失敗なので、
  /// ユーザーが押し直すのは正当な再試行になる。
  func failNextInjection() {
    failingInjections += 1
  }

  func hold(_ command: String) {
    heldCommands.insert(command)
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
    for _ in 0..<100_000 {
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
    if command == "load-buffer", failingInjections > 0 {
      failingInjections -= 1
      return ProcessRunResult(
        exitCode: 1, stdout: "", stderr: "no server running on /private/tmp/awt-test.sock\n")
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

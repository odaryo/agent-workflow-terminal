import Adapters
import Foundation
import SwiftUI
import TerminalCore

@MainActor
final class AppModel: ObservableObject {
  @Published private(set) var projectRoot: DetectedWorktree? {
    didSet { paneObservations.observe(inventory, sessions: sessionKeys) }
  }
  @Published private(set) var worktrees: [TaskWorktree] = [] {
    didSet { paneObservations.observe(inventory, sessions: sessionKeys) }
  }
  @Published var displayedSession: TerminalSessionKey?
  @Published var openedSessions: Set<TerminalSessionKey> = []
  @Published private(set) var sessionLayout = TerminalTabLayout() {
    didSet { paneObservations.observe(inventory, sessions: sessionKeys) }
  }
  var newlyAddedSessions: Set<TerminalSessionKey> = []
  var restoredSessions: Set<TerminalSessionKey> = []

  @Published var viewerDrawerLayout = ViewerArrangementPreferences.restoredLayout() {
    didSet { saveViewerArrangements(replacing: oldValue) }
  }
  @Published private(set) var message: String?
  /// `message` と分ける。あちらはコンテンツ全体を `ContentUnavailableView` へ差し替えるため、
  /// 端末を出したまま伝えるべき失敗 (Active/Inactive の保存など) をあちらへ載せると、
  /// 致命的でない失敗で端末が消える。
  @Published private(set) var warning: String?
  /// `warning` と分ける。同じスロットに載せると、`prepare(for:)` が立てた「この起動では
  /// Active/Inactive を保存しません」がスキャンのたびに上書きされ、観測失敗が解消した時点で
  /// 恒久的に消える (保存できないままユーザーへの通知だけが消える)。2つの通知は互いに
  /// 独立していて、どちらも取り下げられない。
  @Published private(set) var scanFailureWarning: String?

  let tmuxExecutable: URL?
  /// `nil` は tmux を使えない起動。`tmuxExecutable` が `nil` の起動と同じ集合になる。
  let sessions: TmuxSessionProvisioner?
  /// pane 観測はここで session ごとに1本だけ回す。セッション・Drawer・Overview はどれも
  /// これを読み、自分で観測を起こさない。
  let paneObservations: PaneObservationStore
  let diffModels = DiffViewerModelStore()
  let mainPanes: MainPaneCoordinator
  /// Close の確認と実行 (設計書 §3.4)。
  let closing: WorktreeClosing
  let sessionClosing = TerminalSessionClosing()
  let sessionActivityProbe: TmuxSessionActivityProbe?
  let project: RegisteredProject
  private let projectDirectory: URL
  private let applicationSupportDirectory: URL?
  private var store: WorktreeInventoryStore?
  /// 保存されたファイルを読めなかった起動では `false`。読めなかったファイルを上書きすると、
  /// ユーザーが手で復旧できる可能性まで消える。`stop()` の後も `false` (登録解除後に書かない)。
  private var canSave = false
  private let rescan = DetachedOnceTask()
  let hostControlRescan = HostControlRescan()
  /// `rescan` と分ける。あちらは `run()` の二重起動を防ぐ側で、スキャンが**終わった**ことは
  /// 表さない。空の一覧を「worktree が無い」と読んでよいのは、この印が立った後だけである。
  @Published private(set) var didCompleteInitialScan = false
  private(set) var pendingSave: Task<Void, Never>?
  /// 直近のスキャンの一覧取得失敗と entry の失敗の集合。**毎回バナーへ代入しない**ための状態で、
  /// これが変わらない限り再表示しない。5 秒ごとの再スキャンで代入すると、ユーザーが閉じた
  /// バナーが閉じた直後に復活し、端末の上に貼り付いたままになる。
  private var reportedScanFailures: Set<String> = []

  /// 再スキャンの間隔。P1 の暫定値で、根拠は pane 観測 (`makeWorktreePaneStatesFeed`) と同じく
  /// 「体感で追随し、git への負荷が無視できる」程度でしかない。
  private let rescanInterval: Duration
  private var reportedInitialScanFailure: String?

  init(
    project: RegisteredProject, dependencies: AppDependencies, notifier: PaneNotifier?,
    rescanInterval: Duration = .seconds(5)
  ) {
    self.rescanInterval = rescanInterval
    self.project = project
    projectDirectory = URL(fileURLWithPath: project.directory)
    applicationSupportDirectory = dependencies.applicationSupportDirectory
    tmuxExecutable = dependencies.tmuxExecutable
    sessions =
      if let runner = dependencies.tmuxRunner, let executable = dependencies.tmuxExecutable {
        TmuxSessionProvisioner(runner: runner, tmuxExecutable: executable)
      } else {
        nil
      }
    paneObservations = PaneObservationStore(dependencies: dependencies, notifier: notifier)
    mainPanes = MainPaneCoordinator(runner: dependencies.tmuxRunner)
    closing = WorktreeClosing(tmuxRunner: dependencies.tmuxRunner)
    sessionActivityProbe = dependencies.sessionActivityProbe
    message = dependencies.tmuxError
    // Diff の範囲表示と比較先の候補 (§9.1) が、この Project の一覧を読むための口。
    diffModels.worktreeContext = { [weak self] root in
      DiffWorktreeContext(
        worktreeRoot: root, projectRoot: self?.projectRoot, worktrees: self?.worktrees ?? [])
    }
  }

  var inventory: WorktreeInventory {
    WorktreeInventory(projectRoot: projectRoot, taskWorktrees: worktrees)
  }

  var selectedIdentity: WorktreeIdentity? { displayedSession?.identity }

  var sessionKeys: [TerminalSessionKey] {
    sessionLayout.tabs(
      directories: [projectRoot?.identity].compactMap { $0 } + sessionWorktrees.map(\.identity))
  }

  func selectNewSession(in identity: WorktreeIdentity, existingSessionNames: [String]) {
    guard canOpenSession(in: identity) else { return }
    guard let key = sessionLayout.addTab(in: identity, existingSessionNames: existingSessionNames)
    else {
      reportSessionWarning("セッション番号の上限 (9999) に達したため、新しいセッションを開けません。")
      return
    }
    newlyAddedSessions.insert(key)
    restoredSessions.remove(key)
    select(key)
  }

  func reportSessionWarning(_ detail: String) {
    warning = detail
  }

  func reportSessionClosingFailure(_ detail: String) {
    warning = detail
  }

  func removeSession(_ key: TerminalSessionKey) {
    newlyAddedSessions.remove(key)
    restoredSessions.remove(key)
    openedSessions.remove(key)
    sessionLayout.removeTab(key)
  }

  func removeSessions(in identity: WorktreeIdentity) {
    newlyAddedSessions = newlyAddedSessions.filter { $0.identity != identity }
    restoredSessions = restoredSessions.filter { $0.identity != identity }
    for key in sessionLayout.tabs(in: identity) { sessionLayout.removeTab(key) }
  }
  /// Inactive の worktree はセッションの表示対象にしない (設計書 §3.2)。
  var sessionWorktrees: [TaskWorktree] { inventory.tabbedTaskWorktrees }

  /// Active 化の導線に並べる worktree。状態は添えない — 添えると Inactive の pane を観測する
  /// ことになり、Inactive を観測対象から外す方針に反する (設計書 §3.2)。
  var inactiveWorktrees: [TaskWorktree] { inventory.inactiveTaskWorktrees }

  /// `message` と分ける。あちらは起動時の失敗を載せる保存されたスロットなので、Inactive を
  /// Active 化しても消えず、tmux 起動失敗と同じスロットである以上まとめてクリアもできない。
  ///
  /// - Important: 分岐は `WorktreeInventory.tabEmptyState` が持つ。ここに条件を書くと単体
  ///   テストで押さえられず、初回スキャン前に「無い」と断定する退行を実際に見落とした
  ///   (Issue #237 のレビュー M-1)。ここは文言への写像だけを担う。
  var emptyStateMessage: String? {
    let state = inventory.tabEmptyState(
      hasSelection: selectedIdentity != nil,
      didCompleteInitialScan: didCompleteInitialScan
    )
    return switch state {
    case nil: nil
    case .noWorktrees: "worktree がありません。"
    case .noReachableWorktrees: "到達できる worktree がありません。"
    case .noActiveWorktrees: "Active な worktree がありません。Inactive の一覧から Active にしてください。"
    }
  }

  /// すぐ返る。本体を呼び出し元の `.task` の寿命に乗せると、window を閉じた時点で再スキャンが
  /// 止まり、新しい worktree の追従が働かなくなる
  /// (Issue #238)。ループはアプリの生存期間そのものなので、`self` を握ったままにする。
  func run() {
    let projectDirectory = projectDirectory
    rescan.start { await self.scanAndObserve(projectDirectory: projectDirectory) }
  }

  /// 登録を解除した Project の再スキャンを止める (Issue #372)。止めないと一覧から外した
  /// Project へ git を撃ち続け、その保存ファイルを書き続ける。
  func stop() {
    sessionClosing.cancel()
    rescan.cancel()
    hostControlRescan.stop()
    canSave = false
    paneObservations.stopAll()
  }

  private func scanAndObserve(projectDirectory: URL) async {
    while !Task.isCancelled {
      do {
        let detector = try GitWorktreeDetector(
          projectDirectory: projectDirectory,
          processRunner: FoundationProcessRunner()
        )
        let scan = try await self.scan(with: detector).get()
        guard !Task.isCancelled else { return }
        let saved = await prepare(for: scan)
        guard !Task.isCancelled else { return }
        var sessionNames: [String]?
        do {
          sessionNames = try await sessions?.sessionNames()
        } catch {
          warning = "tmux の session の一覧を取得できないため、前回のセッションを復元できませんでした: \(error)"
        }
        guard !Task.isCancelled else { return }
        applyInitial(
          restoreWorktreeInventory(
            detected: scan.detected,
            saved: saved,
            unobserved: scan.failures.map(\.worktreePath),
            isListingComplete: scan.listingFailure == nil
          ), sessionNames: sessionNames, hasSavedInventory: saved != nil)
        // applyInitial の前に消すと、PaneNotifier のまとめ通知の条件と空の一覧の表示が一瞬崩れる。
        if let reportedInitialScanFailure, message == reportedInitialScanFailure {
          message = nil
        }
        reportedInitialScanFailure = nil
        report(scanFailures: scan.failures, listingFailure: scan.listingFailure)
        await observe(with: detector)
        return
      } catch {
        guard !Task.isCancelled else { return }
        report(scanFailure: "\(error)")
      }
      do {
        try await Task.sleep(for: rescanInterval)
      } catch {
        return
      }
    }
  }

  /// 起動時の1回だけ呼ぶ。2回目以降のスキャンは `reconcileDetectedWorktrees` の担当であり、
  /// 保存を `previous` として渡してはならない (`restoreWorktreeInventory` の doc 参照)。
  private func prepare(for scan: GitWorktreeScanResult) async -> PersistedWorktreeInventory? {
    // 保存先のキーは Project Root の安定 ID なので、Project Root を検出できない Project では
    // 保存先が決まらない。重複した `isProjectRoot` の扱いは `restoreWorktreeInventory` と
    // 揃えて最初の1件を採る。
    guard let projectRootIdentity = scan.detected.first(where: \.isProjectRoot)?.identity else {
      warning = "Project Root を検出できないため、この起動では Active/Inactive を保存しません。"
      return nil
    }
    guard let applicationSupportDirectory else {
      warning = "Application Support を利用できないため、この起動では Active/Inactive を保存しません。"
      return nil
    }

    let store = WorktreeInventoryStore(
      fileURL: WorktreeInventoryStore.defaultFileURL(
        applicationSupportDirectory: applicationSupportDirectory,
        projectRootIdentity: projectRootIdentity
      )
    )
    self.store = store
    do {
      let saved = try await store.load()
      canSave = !Task.isCancelled
      return saved
    } catch {
      // 「保存が無い」(`nil`) と同じ扱いにしない。読めなかったことをユーザーへ伝え、
      // この起動では上書きしない。
      warning = "保存された Active/Inactive を読めませんでした。この起動では保存しません: \(error)"
      return nil
    }
  }

  private func observe(with detector: GitWorktreeDetector) async {
    defer { hostControlRescan.stop() }
    for await _ in hostControlRescan.events(interval: rescanInterval) {
      guard !Task.isCancelled else { return }
      let waiters = hostControlRescan.beginScan()
      defer { hostControlRescan.complete(waiters) }
      // 失敗を空の一覧として適用すると、全 worktree が消失扱いになる。
      guard case .success(let scan) = await scan(with: detector) else { continue }

      report(scanFailures: scan.failures, listingFailure: scan.listingFailure)
      // 観測に失敗した entry を捨てて `detected` だけを渡すと、その worktree は消失扱いになり、
      // ユーザーの Active 指定が保存から消える (Issue #243)。
      let updated = reconcileDetectedWorktrees(
        detected: scan.detected,
        previous: inventory,
        unobserved: scan.failures.map(\.worktreePath),
        isListingComplete: scan.listingFailure == nil
      )
      guard updated.inventory != inventory else { continue }
      projectRoot = updated.inventory.projectRoot
      worktrees = updated.inventory.taskWorktrees
      // 消えた worktree を選択したままだと描画先が無くなり、端末が空になる (Issue #496)。
      reconcileSessionSelection()
      save()
    }
  }

  private func scan(
    with detector: GitWorktreeDetector
  ) async -> Result<GitWorktreeScanResult, GitWorktreeScanError> {
    do {
      let scan = try await detector.scan()
      // 失敗した entry は `detected` に載らないため、呼び出し側が `unobserved` として渡す。
      // 原因の原文はバナーに載せきれないので、ここに残す。
      for failure in scan.failures {
        NSLog("[app] worktree の検出に失敗: \(String(describing: failure))")
      }
      if let listingFailure = scan.listingFailure {
        NSLog("[app] worktree の一覧取得に失敗: \(String(describing: listingFailure))")
      }
      return .success(scan)
    } catch {
      return .failure(error)
    }
  }

  func applyInitial(
    _ result: WorktreeScanResult, sessionNames: [String]?, hasSavedInventory: Bool
  ) {
    projectRoot = result.inventory.projectRoot
    worktrees = result.inventory.taskWorktrees
    if let sessionNames {
      sessionLayout.restore(
        from: sessionNames,
        identities: [projectRoot?.identity].compactMap { $0 } + worktrees.map(\.identity))
    }
    // 選択後では端末の .task が印より先に走り、確認なしで session を作り得る。
    restoredSessions = hasSavedInventory ? Set(sessionKeys) : []
    didCompleteInitialScan = true
    if projectRoot != nil {
      selectProjectRoot()
    } else if let first = firstSelectableWorktree {
      select(first)
    }
    // 選べる worktree が無いことは `message` へ書かない。書くと Inactive を Active 化しても
    // 消えないままになる (`emptyStateMessage`)。
  }

  /// Inactive の worktree は表示対象でないため、選ぶと端末だけが生きたまま残り、
  /// 切り替える手段が無くなる。
  private var firstSelectableWorktree: TaskWorktree? {
    inventory.selectableTaskWorktrees.first
  }

  private func report(scanFailure detail: String) {
    NSLog("[app] worktree を検出できません: \(detail)")
    let failure = "worktree を検出できません: \(detail)"
    // 再試行のたびに同じ値を代入して、@Published の購読者を起こさない。
    guard reportedInitialScanFailure != failure else { return }
    reportedInitialScanFailure = failure
    message = failure
  }

  func setActivation(_ activation: WorktreeActivation, of identity: WorktreeIdentity) {
    guard let index = worktrees.firstIndex(where: { $0.identity == identity }) else { return }
    let worktree = worktrees[index]
    // 到達不能な worktree の Active 化は設計書 §3.2 が認めていない (attach 先が実在しない)。
    guard activation != .active || worktree.detected.isReachable else { return }
    guard worktree.activation != activation else { return }
    worktrees = applyingActivation(activation, of: identity, to: worktrees)
    if activation == .inactive {
      sessionClosing.cancel()
      close(identity)
    } else {
      restoredSessions = restoredSessions.filter { $0.identity != identity }
      Task { await restoreSessionsOnActivation(of: identity) }
    }
    save()
  }

  // 起動時の写しは Inactive の間に古くなり、再起動の有無で復元結果が食い違うため、
  // Active 化のたびに session の一覧を取り直す (Issue #489)。
  private func restoreSessionsOnActivation(of identity: WorktreeIdentity) async {
    let names: [String]
    do {
      names = try await sessions?.sessionNames() ?? []
    } catch {
      // 空の一覧で並べ直すとセッションが全部消える。取得できなかったときは今のセッションを残す。
      warning = "tmux の session の一覧を取得できないため、セッションを復元できませんでした: \(error)"
      return
    }
    guard
      worktrees.contains(where: {
        $0.identity == identity && $0.activation == .active && $0.detected.isReachable
      })
    else { return }

    sessionLayout.restore(from: names, identities: [identity])
    let keys = Set(sessionKeys)
    openedSessions = openedSessions.filter { $0.identity != identity || keys.contains($0) }
    if let displayedSession, displayedSession.identity == identity,
      !keys.contains(displayedSession), let first = sessionLayout.tabs(in: identity).first
    {
      select(first)
    }
  }

  /// 表示対象から外れた worktree の端末を残さない。残すと、表示されていない NSView が first
  /// responder を持ち続け、打鍵が別 worktree の生きた session へ入る窓が開く。
  /// tmux session 自体は残す (設計書 §3.4)。
  private func close(_ identity: WorktreeIdentity) {
    openedSessions = openedSessions.filter { $0.identity != identity }
    guard selectedIdentity == identity else { return }
    selectFallbackSession()
  }

  private func reconcileSessionSelection() {
    let sessions = Set(sessionKeys)
    openedSessions.formIntersection(sessions)
    guard let displayedSession else { return }
    let isSelectable =
      if displayedSession.identity == projectRoot?.identity {
        projectRoot?.isReachable == true
      } else {
        inventory.selectableTaskWorktrees.contains { $0.identity == displayedSession.identity }
      }
    guard !sessions.contains(displayedSession) || !isSelectable else { return }
    selectFallbackSession()
  }

  private func selectFallbackSession() {
    // 到達不能な Project Root へは移さない。`selectProjectRoot()` は worktree の選択と違って
    // 到達可能性を見ないので、自動で呼ぶこの経路が「開けない Project Root を勝手に開く」
    // 入口になる (`select(_:)` の doc コメントにある `$HOME` へ落ちる `new-session`)。
    if projectRoot?.isReachable == true {
      selectProjectRoot()
    } else if let next = firstSelectableWorktree {
      select(next)
    } else {
      displayedSession = nil
    }
  }

  func dismissWarning() {
    warning = nil
  }

  func dismissScanFailureWarning() {
    scanFailureWarning = nil
  }

  func updateScanFailureWarning(_ warning: String?, failures: Set<String>) {
    guard failures != reportedScanFailures else { return }
    reportedScanFailures = failures
    scanFailureWarning = warning
  }

  private func save() {
    guard canSave, let store else { return }
    let snapshot = PersistedWorktreeInventory(inventory)
    // 直前の保存を待ってから書く。actor は1件ずつ実行するが到着順までは決めないため、
    // 待たずに投げると連続した操作で古い方が後に着いて上書きし得る。
    let previous = pendingSave
    pendingSave = Task {
      await previous?.value
      do {
        try await store.save(snapshot)
      } catch {
        warning = "Active/Inactive を保存できませんでした: \(error)"
      }
    }
  }

  /// pane の Agent 状態の観測経路。候補一覧の印 (§12.7) と送信可否 (§9.2.2) の両方がこれを見る。
  /// Project Root も含める — 含めないと Project Root セッションで送信が恒久的に不可になる。
  /// `nil` は「観測経路が無い」で、Inactive・到達不能な worktree と tmux を使えない起動が
  /// ここへ入る。
  ///
  /// - Important: 可否の判定は `WorktreeInventory.observesPaneStates(of:)` に任せ、ここでは
  ///   書き直さない。セッション側とドロワー側がそれぞれ条件を持つと、片方だけが Inactive を外して
  ///   観測が走り続ける。
  ///
  /// 返すのは `paneObservations` の購読で、呼ぶたびに観測を起こすことはない。
  func agentPaneStates(of key: TerminalSessionKey) -> AsyncStream<[PaneAgentState]>? {
    guard inventory.observesPaneStates(of: key.identity) else { return nil }
    return paneObservations.paneStates(of: key)
  }
}

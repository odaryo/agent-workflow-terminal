/// Overview のマージ済みの印 (設計書 §13、Issue #879) のために、branch の先端と既定 branch の先端を
/// 読み、merge を判定する。
public protocol BranchMergeProbing: Sendable {
  /// `refs/heads/<branch>` の先端。読めなければ `nil`。
  func branchTip(_ branch: String) async -> CommitObjectID?
  /// 既定 branch の先端 (`origin/HEAD`、無ければ `projectRootBranch`。設計書 §3.4)。
  /// 決められなければ `nil`。
  func defaultBranchTip(projectRootBranch: String?) async -> CommitObjectID?
  /// 2つの OID についての判定 (ancestor + squash。設計書 §3.4)。
  func mergeStatus(tip: CommitObjectID, destination: CommitObjectID) async -> BranchMergeStatus
}

/// 重い判定をアプリ全体で1件ずつ、来た順に回す。未マージの branch の判定は squash 走査が上限に
/// 張り付き、1件で約5秒かかる (git 2.50.1 実測、Issue #366)。
public actor BranchMergeJudgementQueue {
  private struct Waiter {
    let id: UInt64
    let continuation: CheckedContinuation<Bool, Never>
  }

  private var isRunning = false
  private var waiters: [Waiter] = []
  private var nextWaiterID: UInt64 = 0

  public init() {}

  /// 順番が来る前に呼び出し側の Task が取り消されたら、`operation` を実行せず `nil` を返す。
  /// 順番が来た後の取り消しは `operation` に任せる。
  public func run<T: Sendable>(_ operation: @Sendable () async -> T) async -> T? {
    guard await acquire() else { return nil }
    guard !Task.isCancelled else {
      release()
      return nil
    }
    let value = await operation()
    release()
    return value
  }

  private func acquire() async -> Bool {
    guard !Task.isCancelled else { return false }
    guard isRunning else {
      isRunning = true
      return true
    }
    let id = nextWaiterID
    nextWaiterID += 1
    // 取り消しを順番が来るまで持ち越さない。前の判定が数秒かかると、取り消した呼び出し側
    // (Project の登録解除など) がその間戻れない。
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        waiters.append(Waiter(id: id, continuation: continuation))
      }
    } onCancel: {
      Task { await self.abandon(id) }
    }
  }

  private func abandon(_ id: UInt64) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
    waiters.remove(at: index).continuation.resume(returning: false)
  }

  private func release() {
    guard !waiters.isEmpty else {
      isRunning = false
      return
    }
    waiters.removeFirst().continuation.resume(returning: true)
  }
}

/// 印の台帳。1つの Project に1つ。
///
/// マージ済みは先端だけで覚え、既定 branch が進んでも使い回す。それ以外の答えは既定 branch が
/// 動けば判定し直す (Issue #879 のユーザー決定 2026-11-11)。Close の判定 (`GitBranchMergeCache`) は
/// 既定 branch の先端も鍵に含めたままで、この再利用を使わない —— 選択肢4は branch を消すので、
/// 既定 branch が巻き戻った後の古い答えで消すとデータを失う。
public struct MergedWorktreeMarks: Sendable, Equatable {
  private struct JudgedPair: Sendable, Equatable {
    let tip: CommitObjectID
    let destination: CommitObjectID?
  }

  private var tips: [WorktreeIdentity: CommitObjectID] = [:]
  private var mergedTips: Set<CommitObjectID> = []
  private var judgedPairs: [WorktreeIdentity: JudgedPair] = [:]

  public init() {}

  /// 現在の先端が、マージ済みと判定された先端である worktree。
  public var markedWorktrees: Set<WorktreeIdentity> {
    Set(tips.compactMap { mergedTips.contains($0.value) ? $0.key : nil })
  }

  /// 1周の始めに、読めた先端で現在の状態を置き換える。`tips` に無い worktree (消えた・detached・
  /// 先端を読めなかった) は忘れる。マージ済みの先端の記憶も、`tips` に現れる先端だけに絞る。
  public mutating func observeTips(_ tips: [WorktreeIdentity: CommitObjectID]) {
    self.tips = tips
    mergedTips.formIntersection(tips.values)
    judgedPairs = judgedPairs.filter { tips[$0.key] != nil }
  }

  /// 先端がマージ済みと記録済みなら、既定 branch によらず `false`。そうでなければ、その worktree で
  /// 前回判定した `(tip, destination)` と同じなら `false`。
  public func needsJudgement(
    _ identity: WorktreeIdentity, tip: CommitObjectID, destination: CommitObjectID?
  ) -> Bool {
    guard !mergedTips.contains(tip) else { return false }
    return judgedPairs[identity] != JudgedPair(tip: tip, destination: destination)
  }

  /// `.merged` はその先端をマージ済みとして覚え、worktree をまたいで効く。それ以外は
  /// `(tip, destination)` を覚え、同じ組の判定し直しを止める。
  public mutating func record(
    _ status: BranchMergeStatus, for identity: WorktreeIdentity, tip: CommitObjectID,
    destination: CommitObjectID?
  ) {
    switch status {
    case .merged:
      mergedTips.insert(tip)
    case .unmerged, .unknown, .notApplicable:
      judgedPairs[identity] = JudgedPair(tip: tip, destination: destination)
    }
  }
}

/// 1つの Project の印を、要求のたびに1周ずつ更新する。
///
/// - Important: 判定不能 (`.unknown`) も同じ (先端, 既定先端) では判定し直さない。5秒ごとの走査に
///   載せると、判定不能の worktree で数秒の走査が回り続けるため。取り消しで終わった判定は記録しない。
public actor MergedWorktreeMarkRefresher {
  private struct Request: Sendable {
    let targets: [DetectedWorktree]
    let projectRootBranch: String?
  }

  private let probe: any BranchMergeProbing
  private let queue: BranchMergeJudgementQueue
  private let onChange: @Sendable (Set<WorktreeIdentity>) -> Void
  private var marks = MergedWorktreeMarks()
  private var notifiedMarks: Set<WorktreeIdentity> = []
  private var pendingRequest: Request?
  private var cycle: Task<Void, Never>?
  private var isStopped = false

  public init(
    probe: any BranchMergeProbing, queue: BranchMergeJudgementQueue,
    onChange: @escaping @Sendable (Set<WorktreeIdentity>) -> Void
  ) {
    self.probe = probe
    self.queue = queue
    self.onChange = onChange
  }

  /// `targets` は Overview に見出しがある worktree で、Project Root は含めない。
  /// 周回中に来た要求は最後の1つだけを残し、今の周が終わった後に1回だけ回す。
  public func request(targets: [DetectedWorktree], projectRootBranch: String?) {
    guard !isStopped else { return }
    pendingRequest = Request(targets: targets, projectRootBranch: projectRootBranch)
    guard cycle == nil else { return }
    cycle = Task { await self.runPendingCycles() }
  }

  /// 以後の `request` は受け付けない。
  public func stop() {
    isStopped = true
    pendingRequest = nil
    cycle?.cancel()
  }

  private func runPendingCycles() async {
    while let request = pendingRequest, !Task.isCancelled {
      pendingRequest = nil
      await runCycle(request)
    }
    cycle = nil
  }

  private func runCycle(_ request: Request) async {
    var tips: [WorktreeIdentity: CommitObjectID] = [:]
    for target in request.targets where target.isReachable {
      guard let branch = target.branch else { continue }
      tips[target.identity] = await probe.branchTip(branch)
    }
    guard !Task.isCancelled else { return }
    // 先端が変わった worktree の印は、新しい先端の判定 (数秒かかりうる) を待たずに外す。
    marks.observeTips(tips)
    notifyIfChanged()

    let destination = await probe.defaultBranchTip(projectRootBranch: request.projectRootBranch)
    guard !Task.isCancelled else { return }
    for target in request.targets {
      guard let tip = tips[target.identity],
        marks.needsJudgement(target.identity, tip: tip, destination: destination)
      else { continue }
      let status: BranchMergeStatus
      if let destination {
        let probe = probe
        guard
          let judged = await queue.run({
            await probe.mergeStatus(tip: tip, destination: destination)
          }),
          !Task.isCancelled
        else { return }
        status = judged
      } else {
        status = .unknown
      }
      marks.record(status, for: target.identity, tip: tip, destination: destination)
      notifyIfChanged()
    }
  }

  private func notifyIfChanged() {
    let current = marks.markedWorktrees
    guard current != notifiedMarks else { return }
    notifiedMarks = current
    onChange(current)
  }
}

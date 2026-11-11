import TerminalCore
import Testing

enum MarkFixture {
  static func oid(_ digit: Character) throws -> CommitObjectID {
    try #require(CommitObjectID(String(repeating: digit, count: 40)))
  }

  static func identity(_ name: String) throws -> WorktreeIdentity {
    try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/\(name)"))
  }

  static func worktree(
    _ name: String, branch: String?, isReachable: Bool = true
  ) throws -> DetectedWorktree {
    DetectedWorktree(
      identity: try identity(name), worktreePath: "/repo/\(name)", branch: branch,
      isProjectRoot: false, isReachable: isReachable)
  }
}

/// 上限に達したら `false` を返す。成否は呼び出し側の `#require` / `#expect` が記録し、テストは
/// ハングしない (何もしない実装では、待っている呼び出しが永久に来ない)。
func waitUntil(
  timeout: Duration = .seconds(3), _ condition: () async -> Bool
) async -> Bool {
  let deadline = ContinuousClock().now.advanced(by: timeout)
  while ContinuousClock().now < deadline {
    if await condition() { return true }
    try? await Task.sleep(for: .milliseconds(2))
  }
  return await condition()
}

/// 呼び出しを記録し、指定した先端の判定を `release` まで止めておける偽の probe。
actor FakeBranchMergeProbe: BranchMergeProbing {
  struct Judgement: Sendable, Equatable {
    let tip: CommitObjectID
    let destination: CommitObjectID
  }

  private var tips: [String: CommitObjectID]
  private var defaultTip: CommitObjectID?
  /// 登録の無い先端は `.unmerged`。
  private var verdicts: [CommitObjectID: BranchMergeStatus] = [:]
  private var heldTips: Set<CommitObjectID> = []
  private var heldJudgements: [CommitObjectID: [CheckedContinuation<Void, Never>]] = [:]
  private let gauge: JudgementConcurrencyGauge?
  private let judgementDuration: Duration?

  private(set) var branchTipReads: [String] = []
  private(set) var defaultBranchTipQueries: [String?] = []
  private(set) var judgements: [Judgement] = []
  private(set) var finishedJudgements = 0

  init(
    tips: [String: CommitObjectID], defaultTip: CommitObjectID?,
    gauge: JudgementConcurrencyGauge? = nil, judgementDuration: Duration? = nil
  ) {
    self.tips = tips
    self.defaultTip = defaultTip
    self.gauge = gauge
    self.judgementDuration = judgementDuration
  }

  var defaultBranchTipReads: Int { defaultBranchTipQueries.count }

  func setTip(_ tip: CommitObjectID?, for branch: String) {
    tips[branch] = tip
  }

  func setDefaultTip(_ tip: CommitObjectID?) {
    defaultTip = tip
  }

  func setVerdict(_ status: BranchMergeStatus, for tip: CommitObjectID) {
    verdicts[tip] = status
  }

  func markMerged(_ tip: CommitObjectID) {
    verdicts[tip] = .merged(.ancestor, tip: tip)
  }

  func hold(_ tip: CommitObjectID) {
    heldTips.insert(tip)
  }

  func release(_ tip: CommitObjectID) {
    heldTips.remove(tip)
    for waiter in heldJudgements.removeValue(forKey: tip) ?? [] {
      waiter.resume()
    }
  }

  func judgementCount(of tip: CommitObjectID) -> Int {
    judgements.count { $0.tip == tip }
  }

  func branchTip(_ branch: String) -> CommitObjectID? {
    branchTipReads.append(branch)
    return tips[branch]
  }

  func defaultBranchTip(projectRootBranch: String?) -> CommitObjectID? {
    defaultBranchTipQueries.append(projectRootBranch)
    return defaultTip
  }

  func mergeStatus(tip: CommitObjectID, destination: CommitObjectID) async -> BranchMergeStatus {
    judgements.append(.init(tip: tip, destination: destination))
    await gauge?.enter()
    if heldTips.contains(tip) {
      await withCheckedContinuation { heldJudgements[tip, default: []].append($0) }
    }
    if let judgementDuration {
      try? await Task.sleep(for: judgementDuration)
    }
    await gauge?.leave()
    finishedJudgements += 1
    return verdicts[tip] ?? .unmerged
  }
}

/// 複数の probe をまたいで、判定が同時にいくつ走ったかの最大を数える。
actor JudgementConcurrencyGauge {
  private var running = 0
  private(set) var maximum = 0

  func enter() {
    running += 1
    maximum = max(maximum, running)
  }

  func leave() {
    running -= 1
  }
}

actor MarkChangeLog {
  private(set) var values: [Set<WorktreeIdentity>] = []

  var last: Set<WorktreeIdentity>? { values.last }

  func append(_ value: Set<WorktreeIdentity>) {
    values.append(value)
  }
}

/// `onChange` は同期の closure なので、受け取った順を崩さないよう `AsyncStream` で1本の Task へ
/// 渡して記録する。closure の中で `Task { await log.append }` を起こすと、Task の起動順は
/// 保証されず、「同じ値で続けて呼ばない」を観測できなくなる。
struct MarkChangeRecorder: Sendable {
  let onChange: @Sendable (Set<WorktreeIdentity>) -> Void
  let log: MarkChangeLog
  private let continuation: AsyncStream<Set<WorktreeIdentity>>.Continuation

  init() {
    let (stream, continuation) = AsyncStream.makeStream(of: Set<WorktreeIdentity>.self)
    let log = MarkChangeLog()
    Task {
      for await value in stream {
        await log.append(value)
      }
    }
    self.log = log
    self.continuation = continuation
    self.onChange = { continuation.yield($0) }
  }

  func finish() {
    continuation.finish()
  }
}

/// 周は1つずつ順に回るので、新しい周が既定 branch の先端を読んだ時点で、それより前の周は終わって
/// いる。前提: 呼ぶ時点で、それまでに要求した周がすべて既定 branch の先端を読み終えていること
/// (そうでないと、前の周の読み取りを今回の周の開始と取り違える)。
func requestCycle(
  _ refresher: MergedWorktreeMarkRefresher, targets: [DetectedWorktree],
  probe: FakeBranchMergeProbe, projectRootBranch: String? = "main"
) async -> Bool {
  let before = await probe.defaultBranchTipReads
  await refresher.request(targets: targets, projectRootBranch: projectRootBranch)
  return await waitUntil { await probe.defaultBranchTipReads > before }
}

/// 直前に要求した周が終わるまで待つ。終わったことは、次の周を1つ要求してその開始で知る
/// (`requestCycle` の前提を参照)。
func settle(
  _ refresher: MergedWorktreeMarkRefresher, targets: [DetectedWorktree],
  probe: FakeBranchMergeProbe
) async -> Bool {
  await requestCycle(refresher, targets: targets, probe: probe)
}

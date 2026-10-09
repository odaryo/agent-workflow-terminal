import Foundation

/// 通知の種類 (設計書 §11.2)。種類ごとに ON / OFF できる。
public enum PaneNotificationKind: String, Sendable, Hashable, CaseIterable, Codable {
  case question
  case permission
  case error
  /// `Unknown` のうち大分類が Needs Attention のもの (§12.4.3、要対応(種別不明))。
  case attentionUnspecified
  /// ハーネスが明示したタスク完了 (§12.7)。pane の応答終了 (`AgentState.completed`) ではない。
  case taskCompleted
  case prolongedUnknown

  public init?(attention state: AgentState) {
    switch state {
    case .question: self = .question
    case .permission: self = .permission
    case .error: self = .error
    case .working, .completed, .idle, .unknown: return nil
    }
  }

  /// 判断待ち。アプリが前面で対象のタブを表示している間は出さない種類。
  public var isAttention: Bool {
    switch self {
    case .question, .permission, .error, .attentionUnspecified: true
    case .taskCompleted, .prolongedUnknown: false
    }
  }
}

public struct PaneNotificationSettings: Sendable, Hashable {
  public var enabledKinds: Set<PaneNotificationKind>
  /// 長時間の `Unknown` とみなす継続時間 (§11.2: ON にした場合の既定は10分)。
  public var unknownThreshold: Duration

  /// 既定は §11.2 のとおり、長時間の `Unknown` だけ OFF。
  public static let defaultEnabledKinds: Set<PaneNotificationKind> = [
    .question, .permission, .error, .attentionUnspecified, .taskCompleted,
  ]
  public static let defaultUnknownThreshold = Duration.seconds(600)

  public init(
    enabledKinds: Set<PaneNotificationKind> = defaultEnabledKinds,
    unknownThreshold: Duration = defaultUnknownThreshold
  ) {
    self.enabledKinds = enabledKinds
    self.unknownThreshold = unknownThreshold
  }
}

public struct PaneNotificationEvent: Sendable, Hashable {
  public let worktree: WorktreeIdentity
  public let paneID: PaneID
  public let kind: PaneNotificationKind
  /// `.taskCompleted` のときだけ入る。
  public let completion: AgentStampedValue?

  public init(
    worktree: WorktreeIdentity, paneID: PaneID, kind: PaneNotificationKind,
    completion: AgentStampedValue?
  ) {
    self.worktree = worktree
    self.paneID = paneID
    self.kind = kind
    self.completion = completion
  }
}

public enum PaneNotification: Sendable, Hashable {
  case pane(PaneNotificationEvent)
  /// 「判断待ちが N 件あります」(§11.2)。開くと Overview へ移る。
  case attentionSummary(count: Int)

  /// アプリが前面で、`worktree` のタブがメイン window で選択されている間に出さないもの。
  /// ユーザーがその画面を見ているので判断待ちは出さず、タスク完了は出す (§11.2、現在の推奨)。
  public func isSuppressed(whileShowing worktree: WorktreeIdentity?) -> Bool {
    guard case .pane(let event) = self, let worktree else { return false }
    return event.kind.isAttention && event.worktree == worktree
  }
}

/// pane の状態と完了表示の列から、出すべき通知を決める (設計書 §11.2)。
///
/// - Important: 判断待ちは「その状態へ入った遷移1回につき1回」。`Unknown` (Needs Attention で
///   ないもの) と観測なし (Agent が `.absent` で feed の出力から消えた回) は直前の既知の状態を
///   保つ (`PaneTaskCompletionTracker` と同じ扱い)。保たないと `Question` → `Unknown` →
///   `Question` のたびに鳴る。
/// - Important: 種別不明の注意状態 (§12.4.3) と種類の分かる判断待ちの行き来は、同じ判断待ちの
///   続きとして再通知しない。ただし続きとみなすのは、その判断待ちを**既に知らせた**場合だけ
///   (通知を出した、または前面時の抑止で消費した。基準の時点の判断待ちはまとめ通知に数える
///   種類なら知らせたものとする)。無効な種類で始まった判断待ちが有効な種類へ移ったら新しい
///   遷移として通知する — 続きとみなすと、無効にした種類が有効な種類の通知を飲み込む。
///   知らせたかどうかはその時点の設定で決まり、後から設定を変えても遡って変わらない。
/// - Important: worktree ごとの最初の観測は基準であり遷移とみなさない。状態の基準は
///   `WorktreePaneAgentStates.isComplete` が初めて真になった観測で、それより前の観測は捨てる
///   — feed の最初の yield は adapter の結果が無いので `[]` になり、それを基準にすると次の観測で
///   判断待ちの pane が全部個別に鳴る (#387)。完了表示の基準は最初の `observeCompletions` で、
///   その時点で有効な token は鳴らさない (再起動のたびに古い完了が鳴るのを防ぐ。アプリ停止中に
///   書かれた完了は鳴らない)。Agent プロセスを特定できなかった読み取り (`undetermined`) は
///   完了表示の中身が分からないので基準にせず、基準の時点に在った pane は最初に判定できた
///   読み取りを基準にする。基準の後に現れた pane には広げない — 現れた直後に書かれた token を
///   飲み込むため。
/// - Important: 基準の時点で判断待ちの pane は個別に鳴らさず、「判断待ちが N 件」1件にまとめる。
///   起動直後は Project ごと・worktree ごとに基準を取る時刻がずれるので、まとめ通知は
///   `setSummaryGate(isOpen:at:)` が開いていて、観測を始めた全 worktree が基準を取り終えた時点で
///   出す。基準を取れない worktree が残っても、最初の候補から `summaryMaximumDelay` で出す。
/// - Important: 時刻で満了するもの (長時間の `Unknown`、まとめ通知の上限) は自律的に満了しない。
///   上位レイヤは `nextDeadline` に `advance(to:)` を呼ぶ義務がある
///   (`PaneDisplayStateStabilizer` と同じ契約)。
/// - Note: 無効にした種類も遷移と token は消費する。後で有効にしたときに、過去の遷移を遡って
///   鳴らさない。
public struct PaneNotificationPlanner: Sendable {
  public var settings: PaneNotificationSettings

  /// 基準を取れない worktree を待つ上限。
  public static let summaryMaximumDelay = Duration.seconds(30)

  private enum KnownState: Sendable, Hashable {
    case state(AgentState)
    case attentionUnspecified

    var attentionKind: PaneNotificationKind? {
      switch self {
      case .state(let state): PaneNotificationKind(attention: state)
      case .attentionUnspecified: .attentionUnspecified
      }
    }
  }

  private struct PaneMemory: Sendable {
    let worktree: WorktreeIdentity
    var lastKnown: KnownState?
    var unknownSince: ContinuousClock.Instant?
    var didNotifyUnknown = false
    /// いまの判断待ちを知らせたか。判断待ちを抜けたら下ろす。
    var isAttentionAnnounced = false
    var notifiedCompletions: Set<AgentStampedValue> = []
    /// 完了表示の基準の時点に在ったが、Agent プロセスを特定できず基準を取れていない。
    var awaitsCompletionBaseline = false
    /// 基準の時点で判断待ちだった。まとめ通知を出すまでの間だけ立つ。
    var isSummaryMember = false
  }

  private struct WorktreeMemory: Sendable {
    var hasStatesBaseline = false
    var hasCompletionsBaseline = false
    /// 直近の状態の観測に現れた pane。概要の読み取りから消えても、ここに居れば記憶を捨てない。
    var observedPanes: Set<PaneID> = []
  }

  private var worktrees: [WorktreeIdentity: WorktreeMemory] = [:]
  private var panes: [PaneID: PaneMemory] = [:]
  private var isSummaryGateOpen = false
  private var summaryStartedAt: ContinuousClock.Instant?

  public init(settings: PaneNotificationSettings = PaneNotificationSettings()) {
    self.settings = settings
  }

  public var nextDeadline: ContinuousClock.Instant? {
    var deadlines: [ContinuousClock.Instant] = []
    if let summaryStartedAt {
      deadlines.append(summaryStartedAt.advanced(by: Self.summaryMaximumDelay))
    }
    if settings.enabledKinds.contains(.prolongedUnknown) {
      deadlines += panes.values.compactMap { memory in
        guard !memory.didNotifyUnknown, let since = memory.unknownSince else { return nil }
        return since.advanced(by: settings.unknownThreshold)
      }
    }
    return deadlines.min()
  }

  /// 観測を始めた worktree だけを扱う。再び呼ぶと記憶を捨てて基準を取り直す。
  public mutating func startObserving(
    _ worktree: WorktreeIdentity, at instant: ContinuousClock.Instant
  ) {
    stopObserving(worktree)
    worktrees[worktree] = WorktreeMemory()
  }

  /// worktree の Inactive 化・Project の登録解除。その pane の記憶をすべて捨てる。
  public mutating func stopObserving(_ worktree: WorktreeIdentity) {
    worktrees[worktree] = nil
    panes = panes.filter { $0.value.worktree != worktree }
  }

  /// 起動直後のまとめ通知を待たせる外部条件 (Project の一覧と初回の worktree 検出が終わったか)。
  public mutating func setSummaryGate(
    isOpen: Bool, at instant: ContinuousClock.Instant
  ) -> [PaneNotification] {
    isSummaryGateOpen = isOpen
    return due(at: instant)
  }

  public mutating func observeStates(
    _ snapshot: WorktreePaneAgentStates, in worktree: WorktreeIdentity,
    at instant: ContinuousClock.Instant
  ) -> [PaneNotification] {
    guard var memory = worktrees[worktree] else { return [] }
    memory.observedPanes = Set(snapshot.panes.map(\.id))
    if !memory.hasStatesBaseline {
      guard snapshot.isComplete else { return [] }
      memory.hasStatesBaseline = true
      worktrees[worktree] = memory
      for pane in snapshot.panes {
        takeBaseline(pane, in: worktree, at: instant)
      }
      return due(at: instant)
    }
    worktrees[worktree] = memory

    var notifications: [PaneNotification] = []
    for (paneID, pane) in panes where pane.worktree == worktree {
      if !memory.observedPanes.contains(paneID) {
        // 観測なし。直前の既知の状態は保ち、Unknown の継続だけ切る。
        panes[paneID]?.unknownSince = nil
        panes[paneID]?.didNotifyUnknown = false
      }
    }
    for pane in snapshot.panes {
      if let kind = transition(pane, in: worktree, at: instant) {
        notifications.append(.pane(event(pane.id, in: worktree, kind: kind)))
      }
    }
    return notifications + due(at: instant)
  }

  /// `displays` はその worktree の全 pane (Agent でない pane を含む) の完了表示。ここにも直近の
  /// 状態の観測にも無い pane は消えたものとして記憶を捨てる。`undetermined` はこの回 Agent
  /// プロセスを特定できなかった pane (`PaneTaskCompletionTracker.isUndetermined`)。
  public mutating func observeCompletions(
    _ displays: [PaneID: PaneTaskCompletionDisplay], undetermined: Set<PaneID>,
    in worktree: WorktreeIdentity, at instant: ContinuousClock.Instant
  ) -> [PaneNotification] {
    guard var memory = worktrees[worktree] else { return [] }
    panes = panes.filter { paneID, pane in
      pane.worktree != worktree || displays[paneID] != nil
        || memory.observedPanes.contains(paneID)
    }
    let isBaseline = !memory.hasCompletionsBaseline
    memory.hasCompletionsBaseline = true
    worktrees[worktree] = memory

    var notifications: [PaneNotification] = []
    for (paneID, display) in displays.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
      var isSilent = isBaseline
      if isBaseline || panes[paneID]?.awaitsCompletionBaseline == true {
        if undetermined.contains(paneID) {
          panes[paneID, default: PaneMemory(worktree: worktree)].awaitsCompletionBaseline = true
          continue
        }
        panes[paneID]?.awaitsCompletionBaseline = false
        isSilent = true
      }
      let value: AgentStampedValue
      switch display {
      case .none: continue
      case .completed(let completed): value = completed
      case .dismissed(let dismissed):
        panes[paneID, default: PaneMemory(worktree: worktree)].notifiedCompletions.insert(
          dismissed)
        continue
      }
      let inserted = panes[paneID, default: PaneMemory(worktree: worktree)]
        .notifiedCompletions.insert(value).inserted
      if inserted, !isSilent, settings.enabledKinds.contains(.taskCompleted) {
        notifications.append(
          .pane(
            PaneNotificationEvent(
              worktree: worktree, paneID: paneID, kind: .taskCompleted, completion: value)))
      }
    }
    return notifications + due(at: instant)
  }

  public mutating func advance(to instant: ContinuousClock.Instant) -> [PaneNotification] {
    due(at: instant)
  }

  // MARK: - 内部

  private mutating func takeBaseline(
    _ pane: PaneAgentState, in worktree: WorktreeIdentity, at instant: ContinuousClock.Instant
  ) {
    var memory = panes[pane.id] ?? PaneMemory(worktree: worktree)
    memory.lastKnown = Self.known(pane)
    memory.unknownSince = Self.isPlainUnknown(pane) ? instant : nil
    memory.didNotifyUnknown = false
    let kind = memory.lastKnown?.attentionKind
    memory.isSummaryMember = kind != nil
    memory.isAttentionAnnounced = kind.map(settings.enabledKinds.contains) ?? false
    panes[pane.id] = memory
    if memory.isSummaryMember, summaryStartedAt == nil {
      summaryStartedAt = instant
    }
  }

  /// 通知すべき遷移なら、その種類を返す。無効な種類でも記憶は進める。
  private mutating func transition(
    _ pane: PaneAgentState, in worktree: WorktreeIdentity, at instant: ContinuousClock.Instant
  ) -> PaneNotificationKind? {
    var memory = panes[pane.id] ?? PaneMemory(worktree: worktree)
    defer { panes[pane.id] = memory }

    if Self.isPlainUnknown(pane) {
      if memory.unknownSince == nil {
        memory.unknownSince = instant
        memory.didNotifyUnknown = false
      }
      return nil
    }
    memory.unknownSince = nil
    memory.didNotifyUnknown = false

    guard let current = Self.known(pane) else { return nil }
    let previous = memory.lastKnown
    guard let kind = current.attentionKind else {
      memory.lastKnown = current
      memory.isSummaryMember = false
      memory.isAttentionAnnounced = false
      return nil
    }
    let crossesUnspecified =
      current == .attentionUnspecified || previous == .attentionUnspecified
    if previous?.attentionKind != nil,
      current == previous || (crossesUnspecified && memory.isAttentionAnnounced)
    {
      // 同じ判断待ちの続き。種類が分かったら、分かった方を覚える。
      if current != .attentionUnspecified { memory.lastKnown = current }
      return nil
    }
    memory.lastKnown = current
    memory.isSummaryMember = false
    memory.isAttentionAnnounced = settings.enabledKinds.contains(kind)
    return memory.isAttentionAnnounced ? kind : nil
  }

  private mutating func due(at instant: ContinuousClock.Instant) -> [PaneNotification] {
    var notifications: [PaneNotification] = []
    if settings.enabledKinds.contains(.prolongedUnknown) {
      for (paneID, memory) in panes.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
        guard !memory.didNotifyUnknown, let since = memory.unknownSince,
          since.advanced(by: settings.unknownThreshold) <= instant
        else { continue }
        panes[paneID]?.didNotifyUnknown = true
        notifications.append(.pane(event(paneID, in: memory.worktree, kind: .prolongedUnknown)))
      }
    }
    if let summary = flushSummary(at: instant) {
      notifications.append(summary)
    }
    return notifications
  }

  private mutating func flushSummary(at instant: ContinuousClock.Instant) -> PaneNotification? {
    let members = panes.filter(\.value.isSummaryMember)
    guard let startedAt = summaryStartedAt, !members.isEmpty else {
      summaryStartedAt = nil
      return nil
    }
    let isSettled = isSummaryGateOpen && worktrees.values.allSatisfy(\.hasStatesBaseline)
    guard isSettled || startedAt.advanced(by: Self.summaryMaximumDelay) <= instant else {
      return nil
    }
    summaryStartedAt = nil
    for paneID in members.keys {
      panes[paneID]?.isSummaryMember = false
    }
    let count = members.values.filter { memory in
      memory.lastKnown?.attentionKind.map(settings.enabledKinds.contains) ?? false
    }.count
    return count > 0 ? .attentionSummary(count: count) : nil
  }

  private func event(
    _ paneID: PaneID, in worktree: WorktreeIdentity, kind: PaneNotificationKind
  ) -> PaneNotificationEvent {
    PaneNotificationEvent(worktree: worktree, paneID: paneID, kind: kind, completion: nil)
  }

  /// `nil` は直前の既知の状態を保つ回 (Needs Attention でない `Unknown`)。
  private static func known(_ pane: PaneAgentState) -> KnownState? {
    guard pane.state == .unknown else { return .state(pane.state) }
    return pane.category == .needsAttention ? .attentionUnspecified : nil
  }

  private static func isPlainUnknown(_ pane: PaneAgentState) -> Bool {
    pane.state == .unknown && pane.category != .needsAttention
  }
}

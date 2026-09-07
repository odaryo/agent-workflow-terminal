import Foundation

/// `rawValue` は `"claude-code"` / `"codex"` / `"process-detection"` のような
/// 安定した識別子を入れる。UI 表示名を入れない (永続化と診断表示に使うため)。
public struct AgentAdapterID: Sendable, Hashable, Codable, RawRepresentable {
  public let rawValue: String
  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

/// フィールドは Spikes/gate1/README.md §8.10 で実測した
/// `#{pane_id}` / `#{pane_pid}` / `#{pane_tty}` / `#{pane_current_command}` /
/// `#{pane_current_path}` / `#{pane_title}` / pane の終了情報に一対一で対応する。
///
/// - Important: libghostty v1.3.1 には `ghostty_surface_foreground_pid` /
///   `tty_name` が存在しないため、プロセス観測を renderer から取らず tmux CLI に寄せている
///   (Spikes/gate1/README.md 申し送り #2、設計書 §21.3 と整合)。
public struct PaneSnapshot: Sendable, Hashable, Codable {
  public let id: PaneID
  /// dead pane では終了済み PID が残り再利用され得るため、`isDead` を確認せず生存確認に使わない。
  public let processID: Int32
  public let tty: String
  public let currentCommand: String
  /// dead pane では空になり得るため、空文字列を観測失敗として扱わない。
  public let currentPath: String
  public let title: String
  /// `nil` は live、`.unknown` は終了済みだが理由を観測できない状態を表す。
  public let termination: ProcessTermination?
  public var isDead: Bool { termination != nil }

  public init(
    id: PaneID,
    processID: Int32,
    tty: String,
    currentCommand: String,
    currentPath: String,
    title: String,
    termination: ProcessTermination?
  ) {
    self.id = id
    self.processID = processID
    self.tty = tty
    self.currentCommand = currentCommand
    self.currentPath = currentPath
    self.title = title
    self.termination = termination
  }
}

public enum UnknownReason: String, Sendable, Hashable, Codable {
  case screenUnavailable
  case signalMissing
  case adapterUndetermined
  case observationFailed
  case livenessUnavailable
}

public enum AgentLiveness: String, Sendable, Hashable, Codable {
  case alive
  case absent
  case undetermined
}

public struct AgentSignals: Sendable, Hashable, Codable {
  public let paneTitle: String
  public let screenText: String?
  /// pane の `capture-pane` 画面が最後に変化してからの秒数。window 単位の
  /// `window_activity` は使わない (Spikes/gate3/README.md §3.3、§3.4)。
  public let secondsSinceScreenChange: TimeInterval?
  public let observedAt: Date

  public init(
    paneTitle: String, screenText: String?, secondsSinceScreenChange: TimeInterval?,
    observedAt: Date
  ) {
    self.paneTitle = paneTitle
    self.screenText = screenText
    self.secondsSinceScreenChange = secondsSinceScreenChange
    self.observedAt = observedAt
  }
}

/// pane ごとの `capture-pane` 結果を比較し、単調時計で最後の画面変化からの経過を測る。
/// 比較対象のない初回と、`forget(paneID:)` 後の初回は `nil` を返す。
/// 画面の変化が Agent の出力とは限らないため、単独で状態を確定する信号にはできない。
public struct AgentScreenChangeTracker: Sendable {
  private struct Entry: Sendable {
    /// 直前の**観測**画面であって「最後に出力と認めた画面」ではない。後者と比較すると
    /// 1行ずつの書き換えが積み上がっていずれ閾値を超え、静止した画面が出力に化ける。
    /// Spikes/gate3/README.md §13 の再採点もこの定義で取っている。
    let screen: String
    let changedAt: ContinuousClock.Instant
  }

  private var entries: [PaneID: Entry] = [:]

  public init() {}

  /// `minimumChangedLines` は出力とみなす最小の変化行数で、1 なら差が1文字でも出力。
  /// Agent ごとの値は `AgentAdapter.minimumChangedLinesForScreenActivity` が持つ。
  /// 0 以下は 1 と同じに扱う (どんな観測も変化になり、経過が常に 0 へ潰れるため)。
  public mutating func observe(
    screen: String, paneID: PaneID, at observedAt: ContinuousClock.Instant,
    minimumChangedLines: Int = 1
  ) -> TimeInterval? {
    guard let previous = entries[paneID] else {
      entries[paneID] = Entry(screen: screen, changedAt: observedAt)
      return nil
    }
    let isOutput = Self.changedLineCount(previous.screen, screen) >= max(1, minimumChangedLines)
    entries[paneID] = Entry(screen: screen, changedAt: isOutput ? observedAt : previous.changedAt)
    guard !isOutput else { return 0 }
    let elapsed = previous.changedAt.duration(to: observedAt).components
    return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
  }

  /// index 単位で数え、行数が違えば短い側を空行で埋める。`capture-pane -p` は pane の高さぶんの
  /// 行を毎回同じ順で返す (tmux 3.4 で実測) ため、行集合の差分ではなく行位置の一致で数えると
  /// 画面の書き換え量に対応する。
  static func changedLineCount(_ lhs: String, _ rhs: String) -> Int {
    let left = lhs.split(separator: "\n", omittingEmptySubsequences: false)
    let right = rhs.split(separator: "\n", omittingEmptySubsequences: false)
    var changed = 0
    for index in 0..<max(left.count, right.count) {
      let leftLine: Substring = index < left.count ? left[index] : ""
      let rightLine: Substring = index < right.count ? right[index] : ""
      if leftLine != rightLine { changed += 1 }
    }
    return changed
  }

  public mutating func forget(paneID: PaneID) {
    entries.removeValue(forKey: paneID)
  }
}

public protocol AgentSignalSource: Sendable {
  /// `minimumChangedLines` は `AgentScreenChangeTracker.observe` へそのまま渡す。
  /// 既定値を与えていないのは、呼び出し側が渡し忘れたときに Agent 固有のしきい値が
  /// 黙って 1 へ戻り、idle が working に見える不具合が再発するため。
  func signals(for pane: PaneSnapshot, minimumChangedLines: Int) async throws -> AgentSignals
  func liveness(for pane: PaneSnapshot, matchingProcessNames: Set<String>) async -> AgentLiveness
  func forget(_ pane: PaneSnapshot) async
}

extension AgentSignalSource {
  public func forget(_ pane: PaneSnapshot) async {}
}

public struct AgentObservationIntervals: Sendable, Hashable {
  public let signals: Duration
  public let liveness: Duration
  public init(signals: Duration, liveness: Duration) {
    self.signals = signals
    self.liveness = liveness
  }
}

/// `AgentState` を裸で返さないのは、`.unknown` のときに「何が分かっているか」を
/// ユーザーへ提示する必要があるため
/// (設計書 §12.3「`Unknown` から Adapter 名、最終成功時刻、エラー詳細を確認できる」)。
public struct AgentStateObservation: Sendable, Hashable, Codable {
  public let state: AgentState
  public let category: WorktreeStateCategory
  public let adapterID: AgentAdapterID
  public let observedAt: Date
  /// 直近で状態を**確定できた**時刻。`observedAt` とは別物で、一度も確定できていなければ `nil`。
  public let lastKnownAt: Date?
  /// `.unknown` / `.error` の理由。診断表示専用で、分岐や差分配信の条件に使わない。
  public let diagnostics: String?
  public let unknownReason: UnknownReason?

  public init(
    state: AgentState, adapterID: AgentAdapterID, observedAt: Date,
    category: WorktreeStateCategory? = nil, lastKnownAt: Date? = nil,
    diagnostics: String? = nil, unknownReason: UnknownReason? = nil
  ) {
    self.state = state
    self.category = category ?? state.worktreeCategory
    self.adapterID = adapterID
    self.observedAt = observedAt
    self.lastKnownAt = lastKnownAt
    self.diagnostics = diagnostics
    self.unknownReason = unknownReason
  }
}

public enum AgentObservationResult: Sendable, Hashable, Codable {
  case observation(AgentStateObservation)
  case absent
}

/// Agent 固有の情報を Terminal 共通状態へ正規化する境界 (設計書 §12.1、§12.4)。
///
/// - Important: この protocol より上のレイヤに、特定 Agent を前提とした分岐を書かない。
///   Agent 固有の知識はすべて実装体の内側に閉じる。
/// - Important: 状態を確定できない場合は `.working` / `.idle` へ丸めず
///   `.unknown` を返す (§12.3)。
public protocol AgentAdapter: Sendable {
  var id: AgentAdapterID { get }
  var processNames: Set<String> { get }
  /// `secondsSinceScreenChange` が 0 に戻る (= 出力があった) とみなす最小の変化行数。
  /// 待機中と実行中で画面が何行動くかは Agent 固有 (claude は分離するが、codex は spinner の
  /// コマ送りで working 中も 1 行しか動かない) なので、既定 1 のまま据え置くか上げるかは
  /// 実装体が決める (Spikes/gate3/README.md §13)。
  var minimumChangedLinesForScreenActivity: Int { get }
  func classify(signals: AgentSignals, liveness: AgentLiveness) -> AgentObservationResult
  func observations(
    of pane: PaneSnapshot, from source: any AgentSignalSource,
    intervals: AgentObservationIntervals
  ) -> AsyncStream<AgentObservationResult>
}

extension AgentAdapter {
  public var minimumChangedLinesForScreenActivity: Int { 1 }

  public func observations(
    of pane: PaneSnapshot, from source: any AgentSignalSource,
    intervals: AgentObservationIntervals
  ) -> AsyncStream<AgentObservationResult> {
    AsyncStream { continuation in
      let task = Task {
        var liveness = AgentLiveness.undetermined
        var nextLivenessCheck: ContinuousClock.Instant?
        var previous: AgentObservationResult?
        var lastKnownAt: Date?
        let clock = ContinuousClock()
        while !Task.isCancelled {
          let now = clock.now
          if nextLivenessCheck.map({ now >= $0 }) ?? true {
            liveness = await source.liveness(for: pane, matchingProcessNames: processNames)
            nextLivenessCheck = now.advanced(by: intervals.liveness)
          }
          let result: AgentObservationResult
          if liveness == .absent {
            await source.forget(pane)
            result = .absent
          } else {
            do {
              let classified = classify(
                signals: try await source.signals(
                  for: pane, minimumChangedLines: minimumChangedLinesForScreenActivity),
                liveness: liveness
              )
              result = Self.withLastKnownAt(classified, previous: &lastKnownAt)
            } catch {
              let failed = AgentObservationResult.observation(
                AgentStateObservation(
                  state: .unknown, adapterID: id, observedAt: Date(),
                  diagnostics: String(describing: error), unknownReason: .observationFailed
                ))
              result = Self.withLastKnownAt(failed, previous: &lastKnownAt)
            }
          }
          if !result.hasSameObservableState(as: previous) {
            continuation.yield(result)
            previous = result
          }
          do { try await Task.sleep(for: intervals.signals) } catch { break }
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private static func withLastKnownAt(
    _ result: AgentObservationResult, previous lastKnownAt: inout Date?
  ) -> AgentObservationResult {
    guard case .observation(let observation) = result else { return result }
    if observation.state != .unknown {
      lastKnownAt = observation.observedAt
    }
    return .observation(
      AgentStateObservation(
        state: observation.state, adapterID: observation.adapterID,
        observedAt: observation.observedAt, category: observation.category,
        lastKnownAt: lastKnownAt, diagnostics: observation.diagnostics,
        unknownReason: observation.unknownReason
      ))
  }
}

extension AgentObservationResult {
  func hasSameObservableState(as other: AgentObservationResult?) -> Bool {
    guard let other else { return false }
    switch (self, other) {
    case (.absent, .absent): return true
    case (.observation(let lhs), .observation(let rhs)):
      return lhs.state == rhs.state && lhs.category == rhs.category
        && lhs.unknownReason == rhs.unknownReason
    default: return false
    }
  }
}

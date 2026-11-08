import Foundation

/// 連携変数1つぶんの読み取り結果 (設計書 §12.7)。
///
/// - Important: tmux は「未設定」と「空文字を書いた」を区別できない (3.4 / 3.7c とも
///   `list-panes` 上は両方とも空文字。実測) ので、未設定は `.value("")` として届く。
public enum PaneUserOptionReading: Sendable, Hashable, Codable {
  case value(String)
  case unreadable(PaneUserOptionUnreadableReason)
}

/// 値を `list-panes -a` に混ぜても他の pane の観測を壊さないよう、tmux 側で値を出さずに
/// 落とした理由。どれも「未設定」と同じに扱う (§12.7)。
public enum PaneUserOptionUnreadableReason: String, Sendable, Hashable, Codable {
  /// 上限はバイト数 (`#{n:}` は UTF-8 のバイト数を返す。実測)。
  case tooLong
  /// LF・CR・0x1F のいずれか。どれも `list-panes` の行・フィールドの区切りを壊し得る。
  case containsLineBreakOrUnitSeparator
  case invalidUTF8
  /// 上の3つ以外で、出力を値へ戻せなかった。tmux の出力として想定外の形。
  case malformedOutput
}

public struct PaneSummaryReadings: Sendable, Hashable, Codable {
  /// `@awt_status` (`<agent-pid> <text>`)。
  public let status: PaneUserOptionReading
  /// `@awt_done` (`<agent-pid> turn=<エポックミリ秒> <token>`)。
  public let completion: PaneUserOptionReading
  /// `@awt_purpose` (`<text>`)。書き手はアプリだけ。
  public let purpose: PaneUserOptionReading

  public init(
    status: PaneUserOptionReading, completion: PaneUserOptionReading,
    purpose: PaneUserOptionReading
  ) {
    self.status = status
    self.completion = completion
    self.purpose = purpose
  }
}

/// 同じ1回の `list-panes` から取った pane と連携変数の組。`pane` は現在の Agent プロセスを
/// 特定する根 (`processID`) と死活に使う。
public struct PaneSummaryReadingsSnapshot: Sendable, Hashable {
  public let pane: PaneSnapshot
  public let readings: PaneSummaryReadings

  public init(pane: PaneSnapshot, readings: PaneSummaryReadings) {
    self.pane = pane
    self.readings = readings
  }
}

/// pane の「現在の Agent プロセス」(§12.7)。pane_pid を根とするプロセス木で、名前が Agent 名の
/// プロセスのうち根に最も近いもの。
public enum PaneAgentProcess: Sendable, Hashable, Codable {
  case identified(processID: Int32)
  /// dead pane を含む。
  case notRunning
  /// 根から同じ深さに複数あった。推測で1つを選ばない。
  case ambiguous(processIDs: [Int32])
  /// プロセス表を読めなかった。
  case unobservable
}

/// `<agent-pid> <text>` (§12.7)。
public struct AgentStampedValue: Sendable, Hashable, Codable {
  public let agentProcessID: Int32
  public let text: String
  public let turnStartedAt: Date?

  public init(agentProcessID: Int32, text: String, turnStartedAt: Date? = nil) {
    self.agentProcessID = agentProcessID
    self.text = text
    self.turnStartedAt = turnStartedAt
  }

  public static func parseCompletion(_ raw: String) -> Parsed {
    parse(raw, includesTurnStart: true)
  }

  public enum Parsed: Sendable, Hashable {
    case unset
    case value(AgentStampedValue)
    case malformed(PaneSummaryFormatViolation)
  }

  /// 先頭の ASCII 10進数 + 半角空白 (U+0020) 1個 + 残り。残りは前後の空白も含めて加工しない。
  public static func parse(_ raw: String) -> Parsed {
    parse(raw, includesTurnStart: false)
  }

  private static func parse(_ raw: String, includesTurnStart: Bool) -> Parsed {
    if raw.isEmpty { return .unset }
    if raw.allSatisfy(\.isWhitespace) { return .malformed(.blank) }
    let scalars = raw.unicodeScalars
    let digitsEnd = scalars.firstIndex { !("0"..."9").contains($0) } ?? scalars.endIndex
    guard digitsEnd != scalars.startIndex else { return .malformed(.missingAgentProcessID) }
    guard digitsEnd != scalars.endIndex, scalars[digitsEnd] == " " else {
      return .malformed(.missingSeparator)
    }
    guard
      let processID = Int32(String(scalars[scalars.startIndex..<digitsEnd])), processID > 0
    else {
      return .malformed(.agentProcessIDOutOfRange)
    }
    var text = String(scalars[scalars.index(after: digitsEnd)...])
    var turnStartedAt: Date?
    if includesTurnStart {
      guard text.hasPrefix("turn=") else { return .malformed(.missingTurnStart) }
      let turnAndToken = text.unicodeScalars.dropFirst("turn=".unicodeScalars.count)
      guard let separator = turnAndToken.firstIndex(of: " ") else {
        return .malformed(.missingSeparator)
      }
      let milliseconds = turnAndToken[..<separator]
      guard !milliseconds.isEmpty,
        milliseconds.allSatisfy({ ("0"..."9").contains($0) }),
        let value = Int64(String(milliseconds)), value > 0
      else {
        return .malformed(.invalidTurnStart)
      }
      turnStartedAt = Date(timeIntervalSince1970: Double(value) / 1000)
      text = String(turnAndToken[turnAndToken.index(after: separator)...])
    }
    if let violation = PaneSummaryFormatViolation.textViolation(text) {
      return .malformed(violation == .blank ? .emptyText : violation)
    }
    return .value(Self(agentProcessID: processID, text: text, turnStartedAt: turnStartedAt))
  }
}

public enum PaneSummaryFormatViolation: Sendable, Hashable, Codable {
  case missingTurnStart
  case invalidTurnStart
  case blank
  case missingAgentProcessID
  case missingSeparator
  /// 0 または `Int32` に収まらない。
  case agentProcessIDOutOfRange
  /// PID の後ろに見える scalar が無い。
  case emptyText
  /// 本文は1行 (§12.7)。Unicode の制御文字 (Cc: LF / CR / TAB / ESC / U+0085 を含む C1) と
  /// 行区切り・段落区切り (Zl: U+2028 / Zp: U+2029) を拒否する。
  case containsLineBreakOrControlCharacter

  /// 書き込み側 (目的の入力) も同じ判定を使う。読み取り側だけ広げると、書けたのに読めない値が出る。
  public static func breaksSingleLine(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.properties.generalCategory {
    case .control, .lineSeparator, .paragraphSeparator: true
    default: false
    }
  }

  /// 読み取り側が未設定と扱う値を書かず、見えない title が placeholder「目的」を消さないよう、
  /// 読み取り・書き込み・title の表示で共有する。
  /// default-ignorable でない Cf は U+06DD などの見える字形を持つため、Cf を条件にしない。
  /// U+2800 は default-ignorable でも空白でもなく、字形を測らずに見えないと決める規則を
  /// 持たないため対象外とする。
  public static func isInvisibleOnly(_ text: String) -> Bool {
    text.unicodeScalars.allSatisfy {
      $0.properties.isDefaultIgnorableCodePoint
        || CharacterSet.whitespacesAndNewlines.contains($0)
    }
  }

  static func textViolation(_ text: String) -> Self? {
    if text.unicodeScalars.contains(where: breaksSingleLine) {
      return .containsLineBreakOrControlCharacter
    }
    if isInvisibleOnly(text) { return .blank }
    return nil
  }
}

/// `.discarded` は表示上 `.unset` と同じに扱う (§12.7)。理由は診断にだけ使う。
public enum PaneSummaryEntry<Value: Sendable & Hashable>: Sendable, Hashable {
  case unset
  case accepted(Value)
  case discarded(PaneSummaryDiscardReason)

  public var value: Value? {
    guard case .accepted(let value) = self else { return nil }
    return value
  }
}

public enum PaneSummaryDiscardReason: Sendable, Hashable, Codable {
  case unreadable(PaneUserOptionUnreadableReason)
  case malformed(PaneSummaryFormatViolation)
  /// 別の Agent プロセス (前に同じ pane で動いていたもの等) が書いた古い信号。
  case agentProcessMismatch(written: Int32, current: Int32)
  case agentProcessNotRunning(written: Int32)
  case agentProcessAmbiguous(written: Int32, candidates: [Int32])
  case agentProcessUnobservable(written: Int32)
}

/// - Important: 連携由来の値 (現在地・タスク完了) は、書いた PID が現在の Agent プロセスと
///   一致するときだけ受理する。これで Agent の終了・入れ替わりで古い値が残らない (§12.7)。
///   **PID の再利用は検出しない** — Agent 終了後に同じ PID が同じ pane の別 Agent に付くと、
///   前の Agent の値が通る (§12.7 に残存リスクとして記録)。
/// - Note: 目的は PID 照合をしない。pane option なので Agent の再起動を越えて残る (§12.7)。
public struct PaneSummary: Sendable, Hashable {
  public let paneID: PaneID
  public let purpose: PaneSummaryEntry<String>
  public let status: PaneSummaryEntry<String>
  /// `text` が token。表示の解除は `PaneTaskCompletionTracker` が持つ。
  public let completion: PaneSummaryEntry<AgentStampedValue>

  public init(paneID: PaneID, readings: PaneSummaryReadings, agentProcess: PaneAgentProcess) {
    self.paneID = paneID
    self.purpose = Self.purpose(from: readings.purpose)
    self.status =
      switch Self.stamped(from: readings.status, agentProcess: agentProcess) {
      case .unset: .unset
      case .accepted(let value): .accepted(value.text)
      case .discarded(let reason): .discarded(reason)
      }
    self.completion = Self.stamped(
      from: readings.completion, agentProcess: agentProcess,
      parser: AgentStampedValue.parseCompletion)
  }

  private static func purpose(from reading: PaneUserOptionReading) -> PaneSummaryEntry<String> {
    switch reading {
    case .unreadable(let reason): return .discarded(.unreadable(reason))
    case .value(let raw):
      if raw.isEmpty { return .unset }
      if let violation = PaneSummaryFormatViolation.textViolation(raw) {
        return .discarded(.malformed(violation))
      }
      return .accepted(raw)
    }
  }

  private static func stamped(
    from reading: PaneUserOptionReading, agentProcess: PaneAgentProcess,
    parser: (String) -> AgentStampedValue.Parsed = AgentStampedValue.parse
  ) -> PaneSummaryEntry<AgentStampedValue> {
    let raw: String
    switch reading {
    case .unreadable(let reason): return .discarded(.unreadable(reason))
    case .value(let value): raw = value
    }
    let stamped: AgentStampedValue
    switch parser(raw) {
    case .unset: return .unset
    case .malformed(let violation): return .discarded(.malformed(violation))
    case .value(let value): stamped = value
    }
    let written = stamped.agentProcessID
    switch agentProcess {
    case .identified(let current) where current == written: return .accepted(stamped)
    case .identified(let current):
      return .discarded(.agentProcessMismatch(written: written, current: current))
    case .notRunning: return .discarded(.agentProcessNotRunning(written: written))
    case .ambiguous(let candidates):
      return .discarded(.agentProcessAmbiguous(written: written, candidates: candidates))
    case .unobservable: return .discarded(.agentProcessUnobservable(written: written))
    }
  }
}

public enum PaneTaskCompletionDisplay: Sendable, Hashable {
  case none
  case completed(AgentStampedValue)
  case dismissed(AgentStampedValue)
}

/// タスク完了表示の解除 (§12.7: 同じ pane が再び `Working` になったら解除する)。
///
/// - Important: 解除の契機は **直前の既知の状態が `Idle` か `Completed` (応答終了) で、
///   `Working` に入った遷移**だけ。`Working` であること自体を契機にすると、ハーネスは自分の
///   ターンの中で `@awt_done` を書くので完了がそのターンの中で消える。`Question` /
///   `Permission` からの `Working` は同じターンの続きなので、ユーザーが見る前に完了を消さない
///   よう解除しない。`Error` からの遷移も、直前が応答終了だったか判定できないので解除しない。
/// - Important: `Unknown` と観測なし (`nil`) の回は直前の既知の状態を保つ。Claude Code では
///   ユーザーが次のプロンプトを打っている間 adapter が `Unknown` を返すので、通常の流れが
///   `Completed` → `Unknown` → `Working` になる。`Unknown` で直前を上書きすると、完了が一度も
///   解除されない。
/// - Important: 記憶はアプリの寿命だけ持つ。再起動直後は解除の記憶も直前の状態も無いので、
///   pane の状態によらず有効な token を完了として扱い、次に応答終了から Working へ入るまで残す
///   (§12.7 に受け入れる残存挙動として記録)。
/// - Important: 応答終了の観測時刻 tL (`lastTurnEndObservedAt`) は、Idle / Completed を最後に
///   観測した capture を発行する直前の時刻を渡す。状態の変化の回しか配信されない feed では、
///   状態の最初の観測時刻 (`lastUpdatedAt`) を使うと、Completed が続く間に走った短いターンの完了が残る。
///   受信時刻だと Completed の capture と次のターン開始の差が数十 ms (実測 64〜77 ms) しかなく、
///   次のターンの完了まで失う。`@awt_done` の開始時刻はエポックミリ秒で書くこと。
///   秒へ切り捨ててから 1000 倍すると、同じ秒に始まった次のターンの完了を失う (設計書 §12.7)。
/// - Note: ターンの途中で誤った Idle / Completed を観測すると、そのターンの完了を失い得る
///   (設計書 §12.7 の残存挙動)。
public struct PaneTaskCompletionTracker: Sendable {
  private struct Entry: Sendable {
    var lastKnownState: AgentState?
    var lastTurnEndObservedAt: Date?
    var dismissBefore: Date?
    var display = PaneTaskCompletionDisplay.none
  }

  private static let turnEndingStates: Set<AgentState> = [.idle, .completed]

  private var entries: [PaneID: Entry] = [:]

  public init() {}

  /// `agentState` は adapter の観測そのもの (`PaneAgentState.state`) を渡す。`nil` は観測が
  /// まだ無いか Agent が居ないことを表す。
  public mutating func update(
    paneID: PaneID, completion: PaneSummaryEntry<AgentStampedValue>, agentState: AgentState?,
    lastTurnEndObservedAt observedAt: Date? = nil
  ) -> PaneTaskCompletionDisplay {
    var entry = entries[paneID] ?? Entry()
    if let observedAt {
      entry.lastTurnEndObservedAt = max(entry.lastTurnEndObservedAt ?? observedAt, observedAt)
    }
    if agentState == .working, let previous = entry.lastKnownState,
      Self.turnEndingStates.contains(previous), let turnEnd = entry.lastTurnEndObservedAt
    {
      let threshold = Date(
        timeIntervalSince1970: floor(turnEnd.timeIntervalSince1970 * 1000) / 1000)
      entry.dismissBefore = max(entry.dismissBefore ?? threshold, threshold)
    }
    if let agentState, agentState != .unknown {
      entry.lastKnownState = agentState
    }
    if Self.isUndetermined(completion) {
      entries[paneID] = entry
      return entry.display
    }
    entry.display =
      switch completion.value {
      case nil: .none
      case let current?:
        if let turnStartedAt = current.turnStartedAt, let dismissBefore = entry.dismissBefore,
          turnStartedAt < dismissBefore
        {
          .dismissed(current)
        } else {
          .completed(current)
        }
      }
    entries[paneID] = entry
    return entry.display
  }

  /// この回の token を特定できず表示を空にすると、完了通知が二重になるため直前の表示を保つ。
  public static func isUndetermined(_ completion: PaneSummaryEntry<AgentStampedValue>) -> Bool {
    switch completion {
    case .discarded(.agentProcessUnobservable), .discarded(.agentProcessAmbiguous): true
    default: false
    }
  }

  public mutating func forget(paneID: PaneID) {
    entries.removeValue(forKey: paneID)
  }
}

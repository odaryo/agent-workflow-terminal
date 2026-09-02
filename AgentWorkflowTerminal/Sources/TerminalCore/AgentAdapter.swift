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
  /// dead pane では終了済み PID が残り、OS に再利用され得るためプロセス観測に使わない。
  public let processID: Int32
  public let tty: String
  public let currentCommand: String
  /// dead pane では空になり得るため、空文字列を観測失敗として扱わない。
  public let currentPath: String
  public let title: String
  /// `nil` は live を表し、`.unknown` は終了済みだが理由を観測できない状態を表す。
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

/// `AgentState` を裸で返さないのは、`.unknown` のときに「何が分かっているか」を
/// ユーザーへ提示する必要があるため
/// (設計書 §12.3「`Unknown` から Adapter 名、最終成功時刻、エラー詳細を確認できる」)。
public struct AgentStateObservation: Sendable, Hashable, Codable {
  public let state: AgentState
  public let adapterID: AgentAdapterID
  public let observedAt: Date
  /// 直近で状態を**確定できた**時刻。`observedAt` とは別物で、一度も確定できていなければ `nil`。
  public let lastKnownAt: Date?
  /// `.unknown` / `.error` の理由。診断表示専用で、分岐の条件に使わない。
  public let diagnostics: String?

  public init(
    state: AgentState,
    adapterID: AgentAdapterID,
    observedAt: Date,
    lastKnownAt: Date? = nil,
    diagnostics: String? = nil
  ) {
    self.state = state
    self.adapterID = adapterID
    self.observedAt = observedAt
    self.lastKnownAt = lastKnownAt
    self.diagnostics = diagnostics
  }
}

/// Agent 固有の情報を Terminal 共通状態へ正規化する境界 (設計書 §12.1)。
///
/// - Important: この protocol より上のレイヤに、特定 Agent (Claude Code 等) を
///   前提とした分岐を書かない。Agent 固有の知識はすべて実装体の内側に閉じる。
/// - Important: 状態を確定できない場合は `.working` / `.idle` へ丸めず
///   `.unknown` を返す (§12.3)。
///
/// - Note: Phase 1 時点では宣言のみで実装体を持たない。取得可能な signal と
///   `Permission` / `Question` / `Completed` / `Error` の厳密な検出条件は
///   設計書 §12.4 で未確定であり、確定後にこの protocol の形も見直す。
///   いま在る形を確定仕様として扱わない。
public protocol AgentAdapter: Sendable {
  var id: AgentAdapterID { get }

  func canHandle(_ pane: PaneSnapshot) -> Bool

  /// 観測に失敗しても `throws` にしないのは、失敗そのものを `.unknown` として
  /// 返す設計だから (§12.3)。呼び出し側に「状態が無い」経路を作らない。
  func observeState(of pane: PaneSnapshot) async -> AgentStateObservation
}

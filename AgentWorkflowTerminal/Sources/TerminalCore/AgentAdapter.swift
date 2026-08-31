import Foundation

/// `AgentAdapter` の識別子 (`claude-code`、`codex`、`process-detection` 等)。
public struct AgentAdapterID: Sendable, Hashable, Codable, RawRepresentable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

/// tmux CLI から観測できる pane の情報。
///
/// フィールドは Spikes/gate1/README.md §8.10 で実測した
/// `#{pane_id}` / `#{pane_pid}` / `#{pane_tty}` / `#{pane_current_command}` /
/// `#{pane_current_path}` / `#{pane_title}` / `#{pane_dead}` に対応する。
///
/// - Important: libghostty v1.3.1 には `ghostty_surface_foreground_pid` /
///   `tty_name` が存在しないため、プロセス観測の一次情報源は tmux CLI とする
///   (Spikes/gate1/README.md 申し送り #2、設計書 §21.3 と整合)。
public struct PaneSnapshot: Sendable, Hashable, Codable {
  public let id: PaneID
  public let processID: Int32
  public let tty: String
  public let currentCommand: String
  public let currentPath: String
  public let title: String
  public let isDead: Bool

  public init(
    id: PaneID,
    processID: Int32,
    tty: String,
    currentCommand: String,
    currentPath: String,
    title: String,
    isDead: Bool
  ) {
    self.id = id
    self.processID = processID
    self.tty = tty
    self.currentCommand = currentCommand
    self.currentPath = currentPath
    self.title = title
    self.isDead = isDead
  }
}

/// Adapter が返す状態観測の結果。
///
/// `state` が `.unknown` の場合に何が分かっているかを併せて返せるようにしている
/// (設計書 §12.3「`Unknown` から Adapter 名、最終成功時刻、エラー詳細を確認できる」)。
public struct AgentStateObservation: Sendable, Hashable, Codable {
  /// 正規化済みの状態。
  public let state: AgentState
  /// 観測を行った Adapter。
  public let adapterID: AgentAdapterID
  /// この観測を行った時刻。
  public let observedAt: Date
  /// 直近で状態を確定できた時刻。一度も確定できていない場合は `nil`。
  public let lastKnownAt: Date?
  /// `.unknown` / `.error` の理由。UI での診断表示に使う。
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
/// ```text
/// AgentAdapter
/// ├─ ClaudeCodeAdapter
/// ├─ CodexAdapter
/// └─ UnsupportedAgentFallback
///         └─ process detection
/// ```
///
/// - Important: この protocol より上のレイヤに、特定 Agent (Claude Code 等) を
///   前提とした分岐を書かない。Agent 固有の知識はすべて実装体の内側に閉じる。
/// - Important: 状態を確定できない場合は `.working` / `.idle` へ丸めず
///   `.unknown` を返す (§12.3)。
///
/// - Note: Phase 1 時点では宣言のみで実装体を持たない。取得可能な signal と
///   `Permission` / `Question` / `Completed` / `Error` の厳密な検出条件は
///   設計書 §12.4 で未確定であり、確定後にこの protocol の形も見直す。
public protocol AgentAdapter: Sendable {
  /// この Adapter の識別子。
  var id: AgentAdapterID { get }

  /// pane がこの Adapter の担当かどうかを判定する。
  func canHandle(_ pane: PaneSnapshot) -> Bool

  /// pane の現在状態を観測する。
  func observeState(of pane: PaneSnapshot) async -> AgentStateObservation
}

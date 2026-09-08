import Foundation

/// メインpane (= 実装Agent pane) の候補 (設計書 §12.7 / §9.2)。
///
/// `isAgent` は選択の**材料**であって根拠ではない。Agent と判定された pane を自動で採用しない
/// (§12.7 確定: 候補が1つでも自動では選ばない)。
public struct MainPaneCandidate: Sendable, Equatable, Identifiable {
  public let pane: PaneSnapshot
  public let isAgent: Bool

  public var id: PaneID { pane.id }

  public init(pane: PaneSnapshot, isAgent: Bool) {
    self.pane = pane
    self.isAgent = isAgent
  }
}

/// 登録先 pane の同一性 (Issue #246)。
///
/// - Important: **`PaneID` だけでは同一性にならない。** tmux は `%N` を server の生存中しか
///   一意に保たず、server が落ちて session が `new-session -A` で作り直されると `%0` から
///   振り直す (隔離ソケットで実測)。ID だけを覚えていると、以前 Agent pane だった `%1` が
///   別用途の pane になっても `registered` のまま送信してしまう。
/// - Important: **`pane_pid` を足しても残余がある。** macOS の PID は 100〜99998 を連番で
///   回すため、fork ループで1周させれば「同じ `%N` かつ同じ `pane_pid`」を作れる
///   (実測: 98,623 forks / 37.8 秒で衝突)。`serverProcessID` は `#{pid}` (tmux server の PID)
///   で、server を跨いで同じ値になるには2つの PID が同時に衝突する必要がある。
/// - Note: `#{pid}` は pane ではなく server の属性で、同じ server の全 pane・全 session で
///   同じ値になる (実測)。`kill-server` を挟むと必ず変わる (実測)。
/// - Note: `respawn-pane` は `%N` を保ったまま `pane_pid` を変えるため、この組では
///   `registeredPaneMissing` になる (実測)。送信先を誤る側ではなく選び直しを促す側に倒れる。
/// - Note: 再起動を跨いでこの値を永続化する場合 (Issue #208)、比較は「同じ server 稼働中」
///   という前提を失う。`serverProcessID` の一致確認が必須になるのはその経路である。
public struct MainPaneRegistration: Sendable, Hashable, Codable {
  public let pane: PaneID
  public let processID: Int32
  public let serverProcessID: Int32

  public init(pane: PaneID, processID: Int32, serverProcessID: Int32) {
    self.pane = pane
    self.processID = processID
    self.serverProcessID = serverProcessID
  }

  public init(_ pane: PaneSnapshot, serverProcessID: Int32) {
    self.init(pane: pane.id, processID: pane.processID, serverProcessID: serverProcessID)
  }
}

/// 登録が残っているのに送信先として使えない理由。
///
/// - Important: 3つを混ぜない。`paneReplaced` では**その `%N` は今も一覧に居る**ので、
///   「存在しません」と表示すると候補一覧に並んでいる pane を指して嘘をつくことになる。
///   `identityUnverifiable` は「別 pane だと分かった」ではなく「同じ pane だと確かめられ
///   なかった」で、`#{pid}` を読めなかった場合 (server 不在に限らず、値のパース失敗でも
///   起こる) がここへ入る。
public enum MainPaneAbsence: Sendable, Equatable {
  case paneGone(PaneID)
  case paneReplaced(PaneID)
  case identityUnverifiable(PaneID)
}

/// - Important: `registeredPaneMissing` を `unregistered` へも `registered` へも丸めない。
///   登録を消して選び直させるか、そのまま待つかはユーザーの判断であり、別 pane への
///   自動的な付け替えは §12.7 が禁じている。
public enum MainPaneResolution: Sendable, Equatable {
  case unregistered(candidates: [MainPaneCandidate])
  case registered(MainPaneRegistration, candidates: [MainPaneCandidate])
  case registeredPaneMissing(
    MainPaneRegistration, MainPaneAbsence, candidates: [MainPaneCandidate])

  /// 選び直しの UI がどの状態からでも候補を出せるように、3つとも同じ候補を持つ。
  public var candidates: [MainPaneCandidate] {
    switch self {
    case .unregistered(let candidates), .registered(_, let candidates),
      .registeredPaneMissing(_, _, let candidates):
      candidates
    }
  }

  /// 登録が残っているのに送信先として使えない場合だけ非 `nil`。
  public var absence: MainPaneAbsence? {
    guard case .registeredPaneMissing(_, let absence, _) = self else { return nil }
    return absence
  }
}

/// worktree ごとに 0 or 1 個のメインpaneを覚える (設計書 §12.7)。
/// 再起動を跨いだ永続化は Issue #208 の対象外で、この型はプロセス内のメモリだけを持つ。
public struct MainPaneRegistry: Sendable, Equatable {
  private var panes: [WorktreeIdentity: MainPaneRegistration] = [:]

  public init() {}

  public func registration(for worktree: WorktreeIdentity) -> MainPaneRegistration? {
    panes[worktree]
  }

  public mutating func register(
    _ registration: MainPaneRegistration, for worktree: WorktreeIdentity
  ) {
    panes[worktree] = registration
  }

  public mutating func clear(for worktree: WorktreeIdentity) {
    panes[worktree] = nil
  }

  /// `panes` は tmux `list-panes` の順序をそのまま渡す。候補は生存 pane だけで、終了した pane
  /// (`PaneSnapshot.isDead`) は候補にも「登録先が存在する」根拠にもしない。
  ///
  /// `serverProcessID` の `nil` は「server の同一性を確かめられなかった」であり、`.registered`
  /// へは倒さない。確かめられないまま送ると Issue #246 の事象がそのまま残る。
  public func resolve(
    for worktree: WorktreeIdentity,
    panes: [PaneSnapshot],
    serverProcessID: Int32?,
    agentPaneIDs: Set<PaneID> = []
  ) -> MainPaneResolution {
    let candidates = panes.filter { !$0.isDead }
      .map { MainPaneCandidate(pane: $0, isAgent: agentPaneIDs.contains($0.id)) }
    guard let registered = registration(for: worktree) else {
      return .unregistered(candidates: candidates)
    }
    let hasSameID = candidates.contains { $0.id == registered.pane }
    guard let serverProcessID else {
      return .registeredPaneMissing(
        registered, hasSameID ? .identityUnverifiable(registered.pane) : .paneGone(registered.pane),
        candidates: candidates)
    }
    guard
      serverProcessID == registered.serverProcessID,
      candidates.contains(where: {
        $0.id == registered.pane && $0.pane.processID == registered.processID
      })
    else {
      return .registeredPaneMissing(
        registered, hasSameID ? .paneReplaced(registered.pane) : .paneGone(registered.pane),
        candidates: candidates)
    }
    return .registered(registered, candidates: candidates)
  }
}

import Adapters
import Foundation
import SwiftUI
import TerminalCore

/// メインpane (= 実装Agent pane) の登録と、そこへのテキスト注入 (設計書 §12.7 / §9.2)。
///
/// 登録は**ユーザーが明示的に選んだときだけ**行う。この型に「候補が1つなら選ぶ」「Agent と
/// 判定された pane を選ぶ」といった自動決定は無い (§12.7 確定)。
@MainActor
final class MainPaneCoordinator: ObservableObject {
  @Published private(set) var registry = MainPaneRegistry()

  private let paneSource: TmuxWorktreePaneSource?
  private let injection: TmuxTextInjection?

  init(runner: TmuxRunner?) {
    paneSource = runner.map(TmuxWorktreePaneSource.init(runner:))
    injection = runner.map(TmuxTextInjection.init(runner:))
  }

  var isAvailable: Bool { paneSource != nil }

  func registeredPane(for worktree: WorktreeIdentity) -> PaneID? {
    registry.registration(for: worktree)?.pane
  }

  func register(_ registration: MainPaneRegistration, for worktree: WorktreeIdentity) {
    registry.register(registration, for: worktree)
  }

  func clear(for worktree: WorktreeIdentity) {
    registry.clear(for: worktree)
  }

  func resolve(
    for worktree: WorktreeIdentity,
    agentPaneIDs: Set<PaneID>
  ) async -> Result<MainPaneObservation, MainPaneLookupFailure> {
    guard let paneSource else {
      return .failure(MainPaneLookupFailure(message: "tmux を利用できないため、送信先の候補を出せません。"))
    }
    let panes: [PaneSnapshot]
    do {
      panes = try await paneSource.panes(of: worktree)
    } catch {
      return .failure(MainPaneLookupFailure(message: "pane の一覧を取得できません: \(error)"))
    }
    let serverProcessID: Int32?
    do {
      // server の同一性は pane 一覧の**後**に読む (`TmuxWorktreePaneSource.serverProcessID`)。
      // 失敗の文言を pane 一覧と分けるのは、読めなかったのがどちらかで次の行動が違うため。
      serverProcessID = try await paneSource.serverProcessID()
    } catch {
      return .failure(
        MainPaneLookupFailure(message: "tmux server の同一性 (#{pid}) を読めません: \(error)"))
    }
    return .success(
      MainPaneObservation(
        resolution: registry.resolve(
          for: worktree, panes: panes, serverProcessID: serverProcessID,
          agentPaneIDs: agentPaneIDs),
        serverProcessID: serverProcessID))
  }

  /// 注入は**貼り付けであって実行ではない** (§9.2.1 制約1)。成功は「pane へ届いた」までしか
  /// 意味せず、Agent が受け取ったことも実行したことも表さない。
  ///
  /// - Important: 登録先が**登録したときの pane のままか**は、`paste-buffer` と同じ tmux
  ///   コマンドの中で照合する (`TmuxTextInjection.inject(_:into:)`)。クライアント側で先に
  ///   確認してから撃つ形と違い、確認と paste の間に tmux server が入れ替わる窓は無い
  ///   (隔離ソケットで実測: 不一致では buffer が消費されず1バイトも届かない)。
  ///   送信先を選ぶ sheet は人が操作するまで開いたままで、しかも出るのは典型的に
  ///   「server が落ちて登録が missing になった直後」なので、この窓は実際に踏まれ得た。
  func inject(
    _ text: String,
    into registration: MainPaneRegistration
  ) async -> Result<Void, MainPaneInjectionFailure> {
    guard let injection else {
      return .failure(.tmuxUnavailable)
    }
    do {
      try await injection.inject(
        text,
        into: TmuxPaneIdentity(
          pane: registration.pane,
          paneProcessID: registration.processID,
          serverProcessID: registration.serverProcessID))
      return .success(())
    } catch .paneIdentityMismatch {
      return .failure(.destinationChanged(registration))
    } catch {
      return .failure(.rejected(error))
    }
  }
}

/// 1回の観測。`resolution` と `serverProcessID` は同じ観測から出た組で、片方だけを後から
/// 使い回さない。UI は選ばれた候補からこの `serverProcessID` で登録を作る。
struct MainPaneObservation: Equatable {
  let resolution: MainPaneResolution
  /// 観測時点の `#{pid}`。`nil` は読めなかったことを表し、この場合は新しい登録を作れない。
  let serverProcessID: Int32?
}

struct MainPaneLookupFailure: Error, Equatable {
  let message: String
}

/// tmux 自体を使えない起動と、注入層が拒否した場合を混ぜない。前者は送信操作が成立しない状態で、
/// 後者は pane の状態や本文に理由がある (`TmuxTextInjectionError`)。
enum MainPaneInjectionFailure: Error, Equatable {
  case tmuxUnavailable
  /// 登録先が、登録したときの pane ではなくなっていた。1バイトも送っていない。
  case destinationChanged(MainPaneRegistration)
  case rejected(TmuxTextInjectionError)
}

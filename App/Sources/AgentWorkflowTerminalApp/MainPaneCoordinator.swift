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
    registry.registeredPane(for: worktree)
  }

  func register(_ pane: PaneID, for worktree: WorktreeIdentity) {
    registry.register(pane, for: worktree)
  }

  func clear(for worktree: WorktreeIdentity) {
    registry.clear(for: worktree)
  }

  func resolve(
    for worktree: WorktreeIdentity,
    agentPaneIDs: Set<PaneID>
  ) async -> Result<MainPaneResolution, MainPaneLookupFailure> {
    guard let paneSource else {
      return .failure(MainPaneLookupFailure(message: "tmux を利用できないため、送信先の候補を出せません。"))
    }
    do {
      let panes = try await paneSource.panes(of: worktree)
      return .success(
        registry.resolve(for: worktree, panes: panes, agentPaneIDs: agentPaneIDs))
    } catch {
      return .failure(MainPaneLookupFailure(message: "pane の一覧を取得できません: \(error)"))
    }
  }

  /// 注入は**貼り付けであって実行ではない** (§9.2.1 制約1)。成功は「pane へ届いた」までしか
  /// 意味せず、Agent が受け取ったことも実行したことも表さない。
  func inject(_ text: String, into pane: PaneID) async -> Result<Void, MainPaneInjectionFailure> {
    guard let injection else {
      return .failure(.tmuxUnavailable)
    }
    do {
      try await injection.inject(text, into: pane)
      return .success(())
    } catch {
      return .failure(.rejected(error))
    }
  }
}

struct MainPaneLookupFailure: Error, Equatable {
  let message: String
}

/// tmux 自体を使えない起動と、注入層が拒否した場合を混ぜない。前者は送信操作が成立しない状態で、
/// 後者は pane の状態や本文に理由がある (`TmuxTextInjectionError`)。
enum MainPaneInjectionFailure: Error, Equatable {
  case tmuxUnavailable
  case rejected(TmuxTextInjectionError)
}

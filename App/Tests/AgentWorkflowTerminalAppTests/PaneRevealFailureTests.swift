import Adapters
import TerminalCore
import Testing

@testable import AgentWorkflowTerminalApp

@Suite("Issue #402 pane へ移れなかった理由の分類")
struct PaneRevealFailureTests {
  private let pane = PaneID(rawValue: "%152")

  @Test("観測に残っていても tmux が pane を見つけられなければ、終了済みとして扱う")
  func paneNotFoundIsGone() {
    let failure = PaneRevealFailure(pane: pane, error: .paneNotFound(pane))

    #expect(failure == .paneGone(pane))
    #expect(failure.description == "pane %152 は既に終了しています。")
  }

  @Test("それ以外の失敗は原因を残して表示する")
  func otherErrorsKeepTheCause() {
    let failure = PaneRevealFailure(pane: pane, error: .invalidPaneID(pane))

    guard case .failed(let failed, let cause) = failure else {
      Issue.record("終了済みに丸めた: \(failure)")
      return
    }
    #expect(failed == pane)
    #expect(cause.contains("invalidPaneID"))
    #expect(failure.description.hasPrefix("pane %152 へ移動できません: "))
  }
}

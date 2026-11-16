import TerminalCore
import Testing

@testable import AgentWorkflowTerminalApp

@MainActor
@Suite("Issue #1025 フォーカスの観測")
struct PaneFocusObservationTests {
  private let first = PaneID(rawValue: "%1")
  private let second = PaneID(rawValue: "%2")

  @Test("フォーカスのある PaneID がちょうど1つのときだけ確定する", arguments: [0, 1, 2])
  func requiresUniqueFocusedPane(count: Int) {
    var observation = PaneObservationStore.Observed(focusedPane: second)
    observation.receiveFocusedPanes(Set([first, second].prefix(count)), listedAt: nil)
    #expect(observation.focusedPane == (count == 1 ? first : nil))
  }

  @Test("選択前と選択から1秒以内に読み終えた一覧では選択を戻さない", arguments: [-1, 0, 500, 1000])
  func retainsSelection(milliseconds: Int) {
    let selectedAt = ContinuousClock.now
    var observation = PaneObservationStore.Observed(focusedPane: first)
    observation.selectFocus(second, at: selectedAt)
    #expect(observation.focusedPane == second)
    observation.receiveFocusedPanes(
      [first], listedAt: selectedAt.advanced(by: .milliseconds(milliseconds)))
    #expect(observation.focusedPane == second)
    observation.receiveFocusedPanes([], listedAt: nil)
    #expect(observation.focusedPane == second)
  }

  @Test("選択と一致する観測を受けたら、その後の端末内の移動にも追従する")
  func releasesSelectionOnMatchingObservation() {
    let selectedAt = ContinuousClock.now
    var observation = PaneObservationStore.Observed()
    observation.selectFocus(second, at: selectedAt)
    observation.receiveFocusedPanes([second], listedAt: nil)
    observation.receiveFocusedPanes([first], listedAt: selectedAt)
    #expect(observation.focusedPane == first)
  }

  @Test("選択から1秒を超えて読み終えた一覧なら不明も含め反映する", arguments: [true, false])
  func releasesSelectionOnFreshListing(hasFocus: Bool) {
    let selectedAt = ContinuousClock.now
    var observation = PaneObservationStore.Observed()
    observation.selectFocus(second, at: selectedAt)
    observation.receiveFocusedPanes(
      hasFocus ? [first] : [], listedAt: selectedAt.advanced(by: .milliseconds(1001)))
    #expect(observation.focusedPane == (hasFocus ? first : nil))
    observation.receiveFocusedPanes([first], listedAt: nil)
    #expect(observation.focusedPane == first)
  }

  @Test("続けて選んだ pane は最後の選択の時刻で保護する")
  func protectsLatestSelection() {
    let selectedAt = ContinuousClock.now
    var observation = PaneObservationStore.Observed()
    observation.selectFocus(first, at: selectedAt)
    observation.selectFocus(second, at: selectedAt.advanced(by: .seconds(1)))
    observation.receiveFocusedPanes(
      [first], listedAt: selectedAt.advanced(by: .milliseconds(1500)))
    #expect(observation.focusedPane == second)
  }
}

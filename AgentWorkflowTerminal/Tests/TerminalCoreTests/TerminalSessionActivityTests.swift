import TerminalCore
import Testing

@Suite("タブを閉じる前の3値の活動状態 (設計書 §3.1)")
struct TerminalSessionActivityTests {
  @Test(
    "判定不能を shellOnly や running と同一視しない",
    arguments: [TerminalSessionActivity.shellOnly, .running, .undetermined])
  func activityStatesRemainDistinct(activity: TerminalSessionActivity) {
    let states: [TerminalSessionActivity] = [.shellOnly, .running, .undetermined]
    #expect(states.filter { $0 == activity }.count == 1)
  }
}

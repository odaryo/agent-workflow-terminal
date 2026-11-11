import Foundation
import Testing

@testable import AgentWorkflowTerminalApp

@Suite("hostctl worktree open の purpose 検査 (Issue #837)")
struct HostControlPurposeTests {
  @Test("purpose が無ければ通す")
  func nilPasses() {
    #expect(hostControlPurposeFailure(nil) == nil)
  }

  @Test("正常な値と見えない文字だけの値は通す")
  func validPasses() {
    #expect(hostControlPurposeFailure("Issue #837 の実装") == nil)
    #expect(hostControlPurposeFailure("") == nil)
  }

  @Test(
    "不正な purpose は invalid_request で、セッションを作る前に弾く",
    arguments: ["目的;", "a\nb", String(repeating: "a", count: 1025)])
  func invalidPurposeRejected(purpose: String) {
    guard case .failure(let code, let message)? = hostControlPurposeFailure(purpose) else {
      Issue.record("失敗にならなかった: \(purpose.count)")
      return
    }
    #expect(code == .invalidRequest)
    #expect(message.hasPrefix("purpose が不正です: "))
  }
}

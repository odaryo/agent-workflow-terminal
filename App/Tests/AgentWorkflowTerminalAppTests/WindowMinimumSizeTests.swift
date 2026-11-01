import Foundation
import Testing

@testable import AgentWorkflowTerminalApp

struct WindowMinimumSizeTests {
  @Test(
    "最小幅に足りない場合だけ画面幅まで広げ、既存の幅は縮めない",
    arguments: [
      WidthCase(current: 900, minimum: 1030, visible: 1440, expected: 1030),
      WidthCase(current: 1030, minimum: 1030, visible: 1440, expected: 1030),
      WidthCase(current: 1200, minimum: 1030, visible: 1440, expected: 1200),
      WidthCase(current: 900, minimum: 1030, visible: 1000, expected: 1000),
      WidthCase(current: 900, minimum: 1030, visible: 800, expected: 900),
      WidthCase(current: 1200, minimum: 480, visible: 1000, expected: 1200),
      WidthCase(current: 501, minimum: 568, visible: 1440, expected: 568),
    ])
  func expandedWidth(values: WidthCase) {
    #expect(
      WindowMinimumSize.expandedWidth(
        current: values.current, minimum: values.minimum, visible: values.visible)
        == values.expected)
  }

  struct WidthCase: Sendable {
    let current: CGFloat
    let minimum: CGFloat
    let visible: CGFloat
    let expected: CGFloat
  }
}

import Testing

@testable import AgentWorkflowTerminalApp

@Suite("§3.4 Close の実行とスキャンの重なり")
struct CloseExecutionOverlapTests {
  @Test("§3.4 実行がなければスキャンは重ならない")
  func noExecution() {
    let overlap = CloseExecutionOverlap()
    let mark = overlap.mark()

    #expect(!overlap.overlapped(since: mark))
  }

  @Test("§3.4 スキャン開始後に実行が始まれば重なる")
  func executionBeginsAfterMark() {
    var overlap = CloseExecutionOverlap()
    let mark = overlap.mark()
    overlap.beginExecution()

    #expect(overlap.overlapped(since: mark))
  }

  @Test("§3.4 スキャン開始後に実行が始まり終わっても重なる")
  func executionBeginsAndFinishesAfterMark() {
    var overlap = CloseExecutionOverlap()
    let mark = overlap.mark()
    overlap.beginExecution()
    overlap.finishExecution()

    #expect(overlap.overlapped(since: mark))
  }

  @Test("§3.4 実行中に始まったスキャンは実行が続いていれば重なる")
  func executionRemainsActiveAfterMark() {
    var overlap = CloseExecutionOverlap()
    overlap.beginExecution()
    let mark = overlap.mark()

    #expect(overlap.overlapped(since: mark))
  }

  @Test("§3.4 実行中に始まったスキャンは実行が終わっても重なる")
  func activeExecutionFinishesAfterMark() {
    var overlap = CloseExecutionOverlap()
    overlap.beginExecution()
    let mark = overlap.mark()
    overlap.finishExecution()

    #expect(overlap.overlapped(since: mark))
  }

  @Test("§3.4 実行が終わった後に始まったスキャンは重ならない")
  func executionFinishesBeforeMark() {
    var overlap = CloseExecutionOverlap()
    overlap.beginExecution()
    overlap.finishExecution()
    let mark = overlap.mark()

    #expect(!overlap.overlapped(since: mark))
  }

  @Test("§3.4 二つの実行の片方だけが終わった後のスキャンは重なる")
  func oneOfTwoExecutionsRemainsActive() {
    var overlap = CloseExecutionOverlap()
    overlap.beginExecution()
    overlap.beginExecution()
    overlap.finishExecution()
    let mark = overlap.mark()

    #expect(overlap.overlapped(since: mark))
  }

  @Test("§3.4 二つの実行が両方終わった後の新しいスキャンは重ならない")
  func bothExecutionsFinishBeforeNewMark() {
    var overlap = CloseExecutionOverlap()
    overlap.beginExecution()
    overlap.beginExecution()
    overlap.finishExecution()
    let previousMark = overlap.mark()
    _ = overlap.overlapped(since: previousMark)
    overlap.finishExecution()
    let mark = overlap.mark()

    #expect(!overlap.overlapped(since: mark))
  }
}

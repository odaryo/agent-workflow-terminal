import TerminalCore
import Testing

@Suite("§7.3 blame の注記をまとめる単位")
struct BlameAnnotationRunsTests {
  @Test("同じ commit が続く行を1つの run にまとめる")
  func groupsConsecutiveLines() {
    #expect(
      BlameAnnotationRuns.runs(of: ["a", "a", "b", "a", "a", "a", "c"])
        == [0..<2, 2..<3, 3..<6, 6..<7])
  }

  @Test("離れた位置に同じ commit が再び現れても、別の run にする")
  func doesNotMergeNonAdjacentLines() {
    #expect(BlameAnnotationRuns.runs(of: ["a", "b", "a"]) == [0..<1, 1..<2, 2..<3])
  }

  @Test("空の入力は run を持たない")
  func emptyInput() {
    #expect(BlameAnnotationRuns.runs(of: [String]()).isEmpty)
  }
}

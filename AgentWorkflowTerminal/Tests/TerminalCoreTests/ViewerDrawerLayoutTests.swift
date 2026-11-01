import TerminalCore
import Testing

@Suite("Viewer Drawer のレイアウト (設計書 §6.1)")
struct ViewerDrawerLayoutTests {
  @Test("既定値は閉じていて Code は左右、Diff は上下、Evidence は並びなし")
  func defaultIsClosed() {
    let layout = ViewerDrawerLayout()
    #expect(layout == .closed)
    #expect(!layout.isOpen)
    #expect(layout.content == nil)
    #expect(layout.arrangements == .defaults)
    #expect(layout.arrangement(for: .code) == .sideBySide)
    #expect(layout.arrangement(for: .diff) == .stacked)
    #expect(layout.arrangement(for: .evidence) == nil)
  }

  @Test("開いて閉じると閉状態へ戻る", arguments: ViewerContent.allCases)
  func opensAndCloses(content: ViewerContent) {
    var layout = ViewerDrawerLayout()
    layout.open(content)
    #expect(layout.isOpen)
    #expect(layout.content == content)

    layout.close()
    #expect(layout == .closed)
    #expect(!layout.isOpen)
    #expect(layout.content == nil)
  }

  @Test(
    "別の内容を開くと置き換わる",
    arguments: ViewerContent.allCases, ViewerContent.allCases)
  func replacesContent(original: ViewerContent, replacement: ViewerContent) {
    var layout = ViewerDrawerLayout()
    layout.open(original)
    layout.open(replacement)
    #expect(layout.isOpen)
    #expect(layout.content == replacement)
  }

  @Test("同じ内容を開く要求は並びを含め何も変えない", arguments: ViewerContent.allCases)
  func ignoresDuplicateContent(content: ViewerContent) {
    var layout = ViewerDrawerLayout(arrangements: .init(code: .stacked, diff: .sideBySide))
    layout.open(content)
    let original = layout
    layout.open(content)
    #expect(layout == original)
  }

  @Test("変更した並びは閉じて開いても保たれる", arguments: ViewerContent.allCases)
  func retainsArrangementsAfterClosing(content: ViewerContent) {
    var layout = ViewerDrawerLayout()
    layout.open(content)
    layout.setArrangement(.stacked, for: .code)
    layout.setArrangement(.sideBySide, for: .diff)
    let saved = ViewerContentArrangements(code: .stacked, diff: .sideBySide)

    layout.close()
    #expect(!layout.isOpen)
    #expect(layout.content == nil)
    #expect(layout.arrangements == saved)
    layout.open(content)
    #expect(layout.isOpen)
    #expect(layout.content == content)
    #expect(layout.arrangements == saved)
    #expect(layout.arrangement(for: .code) == .stacked)
    #expect(layout.arrangement(for: .diff) == .sideBySide)
  }

  @Test("Code と Diff の並びは独立し、内容を切り替えても保たれる")
  func retainsIndependentArrangementsAcrossContentChanges() {
    var layout = ViewerDrawerLayout()
    layout.open(.code)
    layout.setArrangement(.stacked, for: .code)
    #expect(layout.arrangement(for: .code) == .stacked)
    #expect(layout.arrangement(for: .diff) == .stacked)
    #expect(layout.content == .code)

    layout.open(.diff)
    layout.setArrangement(.sideBySide, for: .diff)
    #expect(layout.arrangement(for: .code) == .stacked)
    #expect(layout.arrangement(for: .diff) == .sideBySide)
    #expect(layout.content == .diff)

    layout.open(.code)
    #expect(layout.isOpen)
    #expect(layout.content == .code)
    #expect(layout.arrangement(for: .code) == .stacked)
    #expect(layout.arrangement(for: .diff) == .sideBySide)
    #expect(layout.arrangements == .init(code: .stacked, diff: .sideBySide))
  }

  @Test(
    "Evidence の並び変更は開閉状態に関わらず何も変えない",
    arguments: [nil, ViewerContent.code, .diff, .evidence],
    ViewerContentArrangement.allCases)
  func ignoresEvidenceArrangement(content: ViewerContent?, arrangement: ViewerContentArrangement) {
    var layout = ViewerDrawerLayout(arrangements: .init(code: .stacked, diff: .sideBySide))
    if let content { layout.open(content) }
    let original = layout
    layout.setArrangement(arrangement, for: .evidence)
    #expect(layout == original)
    #expect(layout.arrangement(for: .evidence) == nil)
  }

  @Test("閉じている間にも Code と Diff の並びを変更できる")
  func changesArrangementsWhileClosed() {
    var layout = ViewerDrawerLayout()
    layout.setArrangement(.stacked, for: .code)
    layout.setArrangement(.sideBySide, for: .diff)
    #expect(!layout.isOpen)
    #expect(layout.content == nil)
    #expect(layout.arrangements == .init(code: .stacked, diff: .sideBySide))
    #expect(layout.arrangement(for: .code) == .stacked)
    #expect(layout.arrangement(for: .diff) == .sideBySide)
  }

  @Test(
    "保存した並びを復元して閉じた状態で始まる",
    arguments: ViewerContentArrangement.allCases, ViewerContentArrangement.allCases)
  func restoresArrangements(code: ViewerContentArrangement, diff: ViewerContentArrangement) {
    let saved = ViewerContentArrangements(code: code, diff: diff)
    let layout = ViewerDrawerLayout(arrangements: saved)
    #expect(!layout.isOpen)
    #expect(layout.content == nil)
    #expect(layout.arrangements == saved)
    #expect(layout.arrangement(for: .code) == code)
    #expect(layout.arrangement(for: .diff) == diff)
    #expect(layout.arrangement(for: .evidence) == nil)
  }
}

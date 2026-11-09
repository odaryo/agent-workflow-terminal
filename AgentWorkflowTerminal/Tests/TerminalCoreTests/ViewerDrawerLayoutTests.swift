import TerminalCore
import Testing

@Suite("Viewer Drawer のレイアウト (設計書 §6.1)")
struct ViewerDrawerLayoutTests {
  @Test("既定値は閉じていて Code は左右、Diff は上下")
  func defaultIsClosed() {
    let layout = ViewerDrawerLayout()
    #expect(layout == .closed)
    #expect(!layout.isOpen)
    #expect(layout.content == nil)
    #expect(layout.arrangements == .defaults)
    #expect(layout.arrangement(for: .code) == .sideBySide)
    #expect(layout.arrangement(for: .diff) == .stacked)
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

  @Test("閉じた Viewer を toggle すると指定した種類が開き、並びは保たれる", arguments: ViewerContent.allCases)
  func toggleOpensClosedViewer(content: ViewerContent) {
    let arrangements = ViewerContentArrangements(code: .stacked, diff: .sideBySide)
    var layout = ViewerDrawerLayout(arrangements: arrangements)

    layout.toggle(content)

    #expect(layout.content == content)
    #expect(layout.isOpen)
    #expect(layout.arrangements == arrangements)
  }

  @Test(
    "開いた Viewer を toggle すると同じ種類なら閉じ、別の種類なら置き換え、並びは保たれる",
    arguments: ViewerContent.allCases, ViewerContent.allCases)
  func toggleChangesOpenViewer(original: ViewerContent, requested: ViewerContent) {
    let arrangements = ViewerContentArrangements(code: .stacked, diff: .sideBySide)
    var layout = ViewerDrawerLayout(arrangements: arrangements)
    layout.open(original)

    layout.toggle(requested)

    #expect(layout.content == (original == requested ? nil : requested))
    #expect(layout.isOpen == (original != requested))
    #expect(layout.arrangements == arrangements)
  }

  @Test("変更した並びは閉じて開いても保たれる", arguments: ViewerContent.allCases)
  func retainsArrangementsAfterClosing(content: ViewerContent) {
    var layout = ViewerDrawerLayout()
    layout.open(content)
    layout.setArrangement(.stacked, for: .code)
    layout.setArrangement(.sideBySide, for: .diff)
    #expect(layout.content == content)
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
  }
}

import TerminalCore
import Testing

@Suite("Viewer Drawer のレイアウト (設計書 §6.1)")
struct ViewerDrawerLayoutTests {
  @Test("既定値は閉じている")
  func defaultIsClosed() {
    let layout = ViewerDrawerLayout()
    #expect(layout == .closed)
    #expect(!layout.isOpen)
    #expect(layout.content == nil)
    #expect(layout.presentation == nil)
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
    #expect(layout.presentation == nil)
  }

  @Test("別の内容を開くと置換され表示方法は保たれる", arguments: ViewerDrawerPresentation.allCases)
  func replacesContentKeepingPresentation(presentation: ViewerDrawerPresentation) {
    var layout = ViewerDrawerLayout()
    layout.open(.code)
    layout.setPresentation(presentation)

    layout.open(.diff)
    #expect(layout.content == .diff)
    #expect(layout.presentation == presentation)
    #expect(layout.isOpen)

    layout.open(.evidence)
    #expect(layout.content == .evidence)
    #expect(layout.presentation == presentation)
  }

  @Test("同じ内容を開く要求は何もしない", arguments: ViewerDrawerPresentation.allCases)
  func ignoresDuplicateContent(presentation: ViewerDrawerPresentation) {
    var layout = ViewerDrawerLayout()
    layout.open(.code)
    layout.setPresentation(presentation)
    let original = layout

    layout.open(.code)

    #expect(layout == original)
  }

  @Test("表示方法は開状態だけで変更できる", arguments: ViewerDrawerPresentation.allCases)
  func changesPresentationOnlyWhileOpen(presentation: ViewerDrawerPresentation) {
    var layout = ViewerDrawerLayout()
    layout.setPresentation(presentation)
    #expect(layout == .closed)

    layout.open(.code)
    layout.setPresentation(presentation)
    #expect(layout.presentation == presentation)
    #expect(layout.content == .code)
  }

  @Test("初回は inline で開く")
  func initiallyOpensInline() {
    var layout = ViewerDrawerLayout()

    layout.open(.code)

    #expect(layout.presentation == .inline)
  }

  @Test("overlay で閉じると次回も overlay で開く")
  func retainsOverlayAfterClosing() {
    var layout = ViewerDrawerLayout()
    layout.open(.code)
    layout.setPresentation(.overlay)

    layout.close()
    #expect(!layout.isOpen)
    #expect(layout.content == nil)
    #expect(layout.presentation == nil)
    layout.open(.diff)

    #expect(layout.content == .diff)
    #expect(layout.presentation == .overlay)
  }

  @Test("閉状態での操作は overlay 履歴を含め何も変えない", arguments: [false, true])
  func ignoresOperationsWhileClosed(retainsOverlay: Bool) {
    var layout = ViewerDrawerLayout()
    if retainsOverlay {
      layout.open(.code)
      layout.setPresentation(.overlay)
      layout.close()
    }
    let original = layout

    layout.close()
    layout.setPresentation(.fullscreen)

    #expect(layout == original)
    layout.open(.evidence)
    #expect(layout.presentation == (retainsOverlay ? .overlay : .inline))
  }

  @Test(
    "fullscreen・inline で閉じると次回は inline で開く",
    arguments: [
      ViewerDrawerPresentation.fullscreen, .inline,
    ])
  func reopensInline(presentation: ViewerDrawerPresentation) {
    var layout = ViewerDrawerLayout()
    layout.open(.code)
    layout.setPresentation(presentation)

    layout.close()
    layout.open(.diff)

    #expect(layout.presentation == .inline)
  }

  @Test("overlay 保持後に inline で閉じると次回は inline で開く")
  func resetsRetainedOverlayAfterClosingInline() {
    var layout = ViewerDrawerLayout()
    layout.open(.code)
    layout.setPresentation(.overlay)
    layout.close()
    layout.open(.code)
    layout.setPresentation(.inline)

    layout.close()
    layout.open(.diff)

    #expect(layout.presentation == .inline)
  }

  @Test("開状態では閉状態の overlay 保持履歴を等価性に含めない", arguments: ViewerDrawerPresentation.allCases)
  func ignoresRetainedOverlayHistoryWhileOpen(presentation: ViewerDrawerPresentation) {
    var initialLayout = ViewerDrawerLayout()
    initialLayout.open(.code)
    initialLayout.setPresentation(presentation)

    var reopenedLayout = ViewerDrawerLayout()
    reopenedLayout.open(.code)
    reopenedLayout.setPresentation(.overlay)
    reopenedLayout.close()
    reopenedLayout.open(.code)
    reopenedLayout.setPresentation(presentation)

    #expect(initialLayout == reopenedLayout)
    #expect(initialLayout.hashValue == reopenedLayout.hashValue)
    #expect(Set([initialLayout, reopenedLayout]).count == 1)
  }
}

import TerminalCore
import Testing

@Suite("Viewer Drawer のレイアウト (設計書 §6.1)")
struct ViewerDrawerLayoutTests {
  @Test("既定値は閉じている")
  func defaultIsClosed() {
    #expect(ViewerDrawerLayout() == .closed)
  }

  @Test("主ペインを開いて閉じると閉状態へ戻る")
  func opensAndClosesPrimaryPane() {
    var layout = ViewerDrawerLayout()

    layout.openPrimary(.code)
    #expect(layout.primary == .code)
    #expect(layout.secondary == nil)

    layout.closePrimary()
    #expect(layout == .closed)
  }

  @Test("主ペインを閉じると副ペインが主へ繰り上がる")
  func promotesSecondaryPane() {
    var layout = ViewerDrawerLayout()
    layout.openPrimary(.code)
    layout.openSecondary(.diff)

    #expect(layout.primary == .code)
    #expect(layout.secondary == .diff)

    layout.setPresentation(.fullscreen)
    layout.closePrimary()
    #expect(layout.primary == .diff)
    #expect(layout.secondary == nil)
    #expect(layout.presentation == .fullscreen)
  }

  @Test("単一ペインに同じ内容を副として開く要求は何もしない")
  func ignoresDuplicateSecondaryOnSinglePane() {
    var layout = ViewerDrawerLayout()
    layout.openPrimary(.code)

    layout.openSecondary(.code)

    #expect(layout.primary == .code)
    #expect(layout.secondary == nil)
  }

  @Test("閉状態から副ペインを開くと主ペインとして開く")
  func opensSecondaryRequestAsPrimaryWhenClosed() {
    var layout = ViewerDrawerLayout()

    layout.openSecondary(.evidence)

    #expect(layout.primary == .evidence)
    #expect(layout.secondary == nil)
  }

  @Test("主と同じ内容を副に開く要求は主副を入れ替える")
  func movesExistingPrimaryToSecondary() {
    var layout = ViewerDrawerLayout()
    layout.openPrimary(.diff)
    layout.openSecondary(.code)

    layout.openSecondary(.diff)

    #expect(layout.primary == .code)
    #expect(layout.secondary == .diff)
  }

  @Test("副と同じ内容を主に開く要求は主副を入れ替える")
  func movesExistingSecondaryToPrimary() {
    var layout = ViewerDrawerLayout()
    layout.openPrimary(.code)
    layout.openSecondary(.diff)

    layout.openPrimary(.diff)

    #expect(layout.primary == .diff)
    #expect(layout.secondary == .code)
  }

  @Test("表示方法は開状態だけで変更できる")
  func changesPresentationOnlyWhileOpen() {
    var layout = ViewerDrawerLayout()
    layout.setPresentation(.overlay)
    #expect(layout == .closed)

    layout.openPrimary(.code)
    layout.setPresentation(.fullscreen)
    #expect(layout.presentation == .fullscreen)
  }

  @Test("分割方向は副ペインが無い間と閉状態でも保持する")
  func retainsSplitAxisWithoutSecondaryPane() {
    var layout = ViewerDrawerLayout()
    layout.toggleSplitAxis()
    layout.openPrimary(.evidence)

    #expect(layout.splitAxis == .vertical)

    layout.closeAll()
    #expect(layout.splitAxis == .vertical)

    layout.openPrimary(.code)
    #expect(layout.splitAxis == .vertical)
  }

  @Test("主と副を入れ替える")
  func swapsPanes() {
    var layout = ViewerDrawerLayout()
    layout.openPrimary(.code)
    layout.openSecondary(.evidence)

    layout.swapPanes()

    #expect(layout.primary == .evidence)
    #expect(layout.secondary == .code)
  }

  @Test("副ペインだけを閉じる")
  func closesSecondaryPane() {
    var layout = ViewerDrawerLayout()
    layout.openPrimary(.code)
    layout.openSecondary(.diff)

    layout.closeSecondary()

    #expect(layout.primary == .code)
    #expect(layout.secondary == nil)
  }
}

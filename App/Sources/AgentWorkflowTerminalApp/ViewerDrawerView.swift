import AppKit
import SwiftUI
import TerminalCore

/// 開閉の分岐ごとに `terminal()` を置くと Ghostty サーフェスと tmux client が作り直されるため、
/// 階層上の1箇所に固定し、幅だけを変える。
struct ViewerDrawerView<Terminal: View>: View {
  @Binding var layout: ViewerDrawerLayout
  /// `.code` / `.diff` ペインが起点にする worktree。選択中のタブが無い間は `nil`。
  let worktree: DetectedWorktree?
  let selectedSession: TerminalSessionKey?
  /// Drawer の開閉より長く生きる必要がある Diff の状態 (§9.1.1 の base branch 記憶と
  /// §9.3 の過去 snapshot) を持つ。
  let diffModels: DiffViewerModelStore
  /// Diff コメントの送信先 (§9.2 / §12.7)。
  let mainPanes: MainPaneCoordinator
  /// 候補 pane に Agent の印を付けるための観測経路。無ければ印の無い一覧になる。
  let agentPaneStates: (WorktreeIdentity) -> AsyncStream<[PaneAgentState]>?
  /// Drawer のテキスト入力がキーボードを主張している間、端末に取り返させないための調停役。
  let keyboardFocus: TerminalKeyboardFocus
  @ViewBuilder let terminal: () -> Terminal

  @State private var requestedDrawerWidth = ViewerDrawerMetrics.defaultDrawerWidth

  var body: some View {
    GeometryReader { proxy in
      let metrics = ViewerDrawerMetrics(
        isOpen: layout.isOpen,
        minimumDrawerWidth: minimumDrawerWidth,
        totalWidth: proxy.size.width,
        requestedWidth: requestedDrawerWidth
      )
      ZStack(alignment: .topLeading) {
        terminal()
          .frame(width: metrics.terminalWidth)
        // Why not `frame(height:)`: 高さを固定すると中の pane が縦に広がらず、
        // 幅だけ決めて高さは ZStack の提案をそのまま通す。
        HStack(spacing: 0) {
          Color.clear.frame(width: metrics.drawerOffsetX)
          drawer
            .frame(width: metrics.drawerWidth)
            .background(.windowBackground)
        }
        .opacity(metrics.isDrawerVisible ? 1 : 0)
        .allowsHitTesting(metrics.isDrawerVisible)
        if layout.isOpen {
          DrawerResizeHandle(
            width: metrics.drawerWidth,
            onWidthChange: { requestedDrawerWidth = $0 },
            onDragEnd: { requestedWidth in
              requestedDrawerWidth =
                ViewerDrawerMetrics(
                  isOpen: layout.isOpen,
                  minimumDrawerWidth: minimumDrawerWidth,
                  totalWidth: proxy.size.width,
                  requestedWidth: requestedWidth
                ).drawerWidth
            }
          )
          .frame(width: ViewerDrawerMetrics.resizeHandleWidth, height: proxy.size.height)
          .offset(x: metrics.drawerOffsetX - 4)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private var minimumDrawerWidth: CGFloat {
    ViewerDrawerMetrics.minimumDrawerWidth(
      for: layout.content, arrangement: layout.content.flatMap { layout.arrangement(for: $0) })
  }

  @ViewBuilder
  private var drawer: some View {
    if let content = layout.content {
      pane(content)
    }
  }

  private func pane(_ content: ViewerContent) -> some View {
    VStack(spacing: 0) {
      HStack {
        Label(content.title, systemImage: content.systemImage)
          .fontWeight(.medium)
        Spacer()
        Button("閉じる", systemImage: "xmark") {
          layout.close()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
      }
      .padding(8)
      Divider()
      paneContent(content)
    }
    .frame(minWidth: 160, minHeight: 160)
  }

  private var worktreeRoot: URL? {
    worktree.map { URL(fileURLWithPath: $0.worktreePath) }
  }

  @ViewBuilder
  private func paneContent(_ content: ViewerContent) -> some View {
    switch content {
    case .code:
      if let worktreeRoot {
        // worktree を切り替えたら別の木になるので、状態ごと作り直す。
        CodeViewerPane(worktreeRoot: worktreeRoot, arrangement: layout.arrangements.code)
          .id(worktreeRoot)
      } else {
        unavailable(content)
      }
    case .diff:
      if let worktree, let worktreeRoot {
        DiffViewerPane(
          model: diffModels.model(for: worktreeRoot),
          mainPane: mainPanes,
          worktree: worktree.identity,
          agentPaneStates: { agentPaneStates(worktree.identity) },
          keyboardFocus: keyboardFocus,
          arrangement: layout.arrangements.diff
        )
        .id(
          selectedSession.flatMap { $0.identity == worktree.identity ? $0 : nil }
            ?? .primary(worktree.identity))
      } else {
        unavailable(content)
      }
    case .evidence:
      unavailable(content)
    }
  }

  // Why not VStack への maxHeight: ContentUnavailableView は固有サイズを返すため、
  // VStack 側に maxHeight を付けても中身が中央に寄るだけで上端に揃わない。
  private func unavailable(_ content: ViewerContent) -> some View {
    ContentUnavailableView(content.title, systemImage: content.systemImage)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct ViewerDrawerMetrics {
  static let defaultDrawerWidth: CGFloat = 420
  static let minimumTerminalWidth: CGFloat = 320
  static let resizeHandleWidth: CGFloat = 8

  let terminalWidth: CGFloat
  let drawerWidth: CGFloat
  let drawerOffsetX: CGFloat
  let isDrawerVisible: Bool

  static func minimumDrawerWidth(
    for content: ViewerContent?, arrangement: ViewerContentArrangement?
  ) -> CGFloat {
    guard arrangement == .sideBySide else { return 240 }
    switch content {
    case .code:
      // CodeViewerPane の HSplitView: 一覧 180 + 本文 240 + 区切り 1pt。
      return CodeContentMetrics.sideBySideMinimumWidth
    case .diff:
      // DiffContentLayout の HStack: 一覧 240 + 差分 200 + コメント 260 + 区切り 2 本。
      return DiffContentMetrics.wideMinimumWidth
    case .evidence, nil:
      return 240
    }
  }

  static func minimumWindowWidth(for layout: ViewerDrawerLayout) -> CGFloat {
    guard layout.isOpen else { return 480 }
    let minimum = minimumDrawerWidth(
      for: layout.content, arrangement: layout.content.flatMap { layout.arrangement(for: $0) })
    return max(480, minimumTerminalWidth + minimum + resizeHandleWidth)
  }

  init(
    isOpen: Bool,
    minimumDrawerWidth: CGFloat,
    totalWidth: CGFloat,
    requestedWidth: CGFloat
  ) {
    let total = max(totalWidth, 0)
    isDrawerVisible = isOpen
    if isOpen {
      drawerWidth = CGFloat(
        ViewerDrawerWidth.clamped(
          requested: Double(requestedWidth), total: Double(total),
          minimumDrawer: Double(minimumDrawerWidth),
          minimumTerminal: Double(Self.minimumTerminalWidth)))
      terminalWidth = total - drawerWidth
      drawerOffsetX = terminalWidth
    } else {
      drawerWidth = min(Self.defaultDrawerWidth, total)
      terminalWidth = total
      drawerOffsetX = total - drawerWidth
    }
  }
}

extension ViewerContent {
  fileprivate var title: String {
    switch self {
    case .code: "Code"
    case .diff: "Diff"
    case .evidence: "Evidence"
    }
  }

  fileprivate var systemImage: String {
    switch self {
    case .code: "doc.text"
    case .diff: "arrow.left.arrow.right"
    case .evidence: "checkmark.seal"
    }
  }
}

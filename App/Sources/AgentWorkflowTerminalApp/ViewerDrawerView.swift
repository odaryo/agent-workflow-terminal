import AppKit
import SwiftUI
import TerminalCore

/// Why not `switch layout.presentation`: 分岐ごとに `terminal()` を書くと SwiftUI から見て
/// 別のビューになり、開閉と表示方法の切替のたびに `NSViewRepresentable` が
/// `dismantleNSView` → `makeNSView` される (実測: Ghostty サーフェスと tmux client が毎回作り直され、
/// `.fullscreen` の間は tmux から detach したままになる)。`terminal()` は階層上の1箇所に固定し、
/// 見た目の差は frame / offset / opacity で表す。
struct ViewerDrawerView<Terminal: View>: View {
  @Binding var layout: ViewerDrawerLayout
  /// `.code` / `.diff` ペインが起点にする worktree。選択中のタブが無い間は `nil`。
  let worktree: DetectedWorktree?
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
        presentation: layout.presentation,
        totalWidth: proxy.size.width,
        requestedWidth: requestedDrawerWidth
      )
      ZStack(alignment: .topLeading) {
        terminal()
          .frame(width: metrics.terminalWidth)
          .opacity(metrics.isTerminalVisible ? 1 : 0)
          .allowsHitTesting(metrics.isTerminalVisible)
        // Why not `frame(height:)`: 高さを固定すると中の pane が縦に広がらず、
        // 幅だけ決めて高さは ZStack の提案をそのまま通す。
        HStack(spacing: 0) {
          Color.clear.frame(width: metrics.drawerOffsetX)
          drawer
            .frame(width: metrics.drawerWidth)
            .background(metrics.drawerBackground)
            .shadow(radius: metrics.isDrawerOverlaid ? 8 : 0)
        }
        .opacity(metrics.isDrawerVisible ? 1 : 0)
        .allowsHitTesting(metrics.isDrawerVisible)
        if metrics.isDrawerInline || metrics.isDrawerOverlaid {
          DrawerResizeHandle(
            width: metrics.drawerWidth,
            onWidthChange: { requestedDrawerWidth = $0 },
            onDragEnd: { requestedWidth in
              requestedDrawerWidth =
                ViewerDrawerMetrics(
                  presentation: layout.presentation,
                  totalWidth: proxy.size.width,
                  requestedWidth: requestedWidth
                ).drawerWidth
            }
          )
          .frame(width: 8, height: proxy.size.height)
          .offset(x: metrics.drawerOffsetX - 4)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
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
        CodeViewerPane(worktreeRoot: worktreeRoot)
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
          keyboardFocus: keyboardFocus
        )
        .id(worktreeRoot)
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

/// Drawer を階層から出し入れせずに 3 種類の見た目を作るための寸法。
/// 閉じている間も drawer は階層に残り、幅と可視性だけが変わる。
struct ViewerDrawerMetrics {
  static let defaultDrawerWidth: CGFloat = 420
  private static let minimumDrawerWidth: CGFloat = 240
  private static let minimumTerminalWidth: CGFloat = 320

  let terminalWidth: CGFloat
  let drawerWidth: CGFloat
  let drawerOffsetX: CGFloat
  let isTerminalVisible: Bool
  let isDrawerVisible: Bool
  let isDrawerInline: Bool
  let isDrawerOverlaid: Bool

  var drawerBackground: AnyShapeStyle {
    // overlay だけターミナルの上に重なるため、下が透けない材質を敷く。
    isDrawerOverlaid ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.windowBackground)
  }

  init(
    presentation: ViewerDrawerPresentation?,
    totalWidth: CGFloat,
    requestedWidth: CGFloat
  ) {
    let total = max(totalWidth, 0)
    isDrawerVisible = presentation != nil
    isDrawerInline = presentation == .inline
    isDrawerOverlaid = presentation == .overlay
    isTerminalVisible = presentation != .fullscreen

    switch presentation {
    case .fullscreen:
      drawerWidth = total
      terminalWidth = total
      drawerOffsetX = 0
    case .inline:
      let upperBound = max(Self.minimumDrawerWidth, total - Self.minimumTerminalWidth)
      drawerWidth = min(max(requestedWidth, Self.minimumDrawerWidth), upperBound)
      terminalWidth = max(total - drawerWidth, 0)
      drawerOffsetX = terminalWidth
    case .overlay:
      let upperBound = max(Self.minimumDrawerWidth, total - Self.minimumTerminalWidth)
      drawerWidth = min(min(max(requestedWidth, Self.minimumDrawerWidth), upperBound), total)
      terminalWidth = total
      drawerOffsetX = total - drawerWidth
    case nil:
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

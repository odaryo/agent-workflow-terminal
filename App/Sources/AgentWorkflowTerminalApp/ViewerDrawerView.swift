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
  let worktreeRoot: URL?
  /// Drawer の開閉より長く生きる必要がある Diff の状態 (§9.1.1 の base branch 記憶と
  /// §9.3 の過去 snapshot) を持つ。
  let diffModels: DiffViewerModelStore
  @ViewBuilder let terminal: () -> Terminal

  @State private var requestedInlineDrawerWidth = ViewerDrawerMetrics.defaultDrawerWidth
  @State private var inlineDragBaseWidth: CGFloat?

  var body: some View {
    GeometryReader { proxy in
      let metrics = ViewerDrawerMetrics(
        presentation: layout.presentation,
        totalWidth: proxy.size.width,
        requestedInlineWidth: requestedInlineDrawerWidth
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
            .overlay(alignment: .leading) { inlineResizeHandle(metrics: metrics) }
        }
        .opacity(metrics.isDrawerVisible ? 1 : 0)
        .allowsHitTesting(metrics.isDrawerVisible)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  @ViewBuilder
  private func inlineResizeHandle(metrics: ViewerDrawerMetrics) -> some View {
    if metrics.isDrawerInline {
      Divider()
        .padding(.horizontal, 3)
        .contentShape(.rect)
        .onHover { inside in
          if inside {
            NSCursor.resizeLeftRight.set()
          } else {
            NSCursor.arrow.set()
          }
        }
        .gesture(
          DragGesture(minimumDistance: 1)
            .onChanged { value in
              let base = inlineDragBaseWidth ?? metrics.drawerWidth
              inlineDragBaseWidth = base
              requestedInlineDrawerWidth = base - value.translation.width
            }
            .onEnded { _ in
              inlineDragBaseWidth = nil
              requestedInlineDrawerWidth = metrics.drawerWidth
            }
        )
    }
  }

  @ViewBuilder
  private var drawer: some View {
    if let primary = layout.primary {
      if let secondary = layout.secondary {
        switch layout.splitAxis {
        case .horizontal:
          HSplitView {
            pane(primary, isPrimary: true)
            pane(secondary, isPrimary: false)
          }
        case .vertical:
          VSplitView {
            pane(primary, isPrimary: true)
            pane(secondary, isPrimary: false)
          }
        }
      } else {
        pane(primary, isPrimary: true)
      }
    }
  }

  private func pane(_ content: ViewerContent, isPrimary: Bool) -> some View {
    VStack(spacing: 0) {
      HStack {
        Label(content.title, systemImage: content.systemImage)
          .fontWeight(.medium)
        Spacer()
        Button("閉じる", systemImage: "xmark") {
          if isPrimary {
            layout.closePrimary()
          } else {
            layout.closeSecondary()
          }
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
      if let worktreeRoot {
        DiffViewerPane(model: diffModels.model(for: worktreeRoot))
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
private struct ViewerDrawerMetrics {
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
    requestedInlineWidth: CGFloat
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
      drawerWidth = min(max(requestedInlineWidth, Self.minimumDrawerWidth), upperBound)
      terminalWidth = max(total - drawerWidth, 0)
      drawerOffsetX = terminalWidth
    case .overlay, nil:
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

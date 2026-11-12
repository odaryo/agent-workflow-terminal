import SwiftTerm
import SwiftUI

@MainActor
final class MobileTerminal: NSObject, TerminalViewDelegate {
  let view = MeasuredTerminalView(frame: .zero)
  var channel: SSHTerminalChannel? {
    didSet {
      if channel != nil { _ = view.becomeFirstResponder() }
    }
  }
  var dimensions: TerminalDimensions { view.terminalDimensions }

  private var hasLayout = false
  private var isClosed = false
  private var layoutReply: CheckedContinuation<Bool, Never>?

  override init() {
    super.init()
    view.terminalDelegate = self
    view.onLayout = { [weak self] in
      guard let self, !isClosed else { return }
      hasLayout = true
      let reply = layoutReply
      layoutReply = nil
      reply?.resume(returning: true)
    }
  }

  func waitForLayout() async -> Bool {
    if isClosed { return false }
    if hasLayout { return true }
    return await withCheckedContinuation { layoutReply = $0 }
  }

  func feed(_ bytes: [UInt8]) {
    guard !isClosed else { return }
    view.feed(byteArray: bytes[...])
  }

  func close() {
    isClosed = true
    channel = nil
    let reply = layoutReply
    layoutReply = nil
    reply?.resume(returning: false)
    _ = view.resignFirstResponder()
  }

  func send(source: TerminalView, data: ArraySlice<UInt8>) {
    channel?.write(Array(data))
  }

  func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
    guard newCols > 0, newRows > 0 else { return }
    channel?.resize(columns: newCols, rows: newRows)
  }

  func setTerminalTitle(source: TerminalView, title: String) {}
  func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
  func scrolled(source: TerminalView, position: Double) {}
  func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

@MainActor
final class MeasuredTerminalView: TerminalView {
  var onLayout: (() -> Void)?

  override func layoutSubviews() {
    super.layoutSubviews()
    guard bounds.width > 0, bounds.height > 0,
      terminalDimensions.cols > 0, terminalDimensions.rows > 0
    else { return }
    onLayout?()
  }
}

@MainActor
struct RemoteTerminalView: UIViewRepresentable {
  let terminal: MobileTerminal

  func makeUIView(context: Context) -> MeasuredTerminalView { terminal.view }
  func updateUIView(_ uiView: MeasuredTerminalView, context: Context) {}
}

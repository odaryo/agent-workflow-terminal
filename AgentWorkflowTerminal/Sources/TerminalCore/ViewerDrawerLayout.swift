public enum ViewerContent: Sendable, Hashable, CaseIterable {
  case code
  case diff
  case evidence
}

public enum ViewerDrawerPresentation: Sendable, Hashable, CaseIterable {
  case inline
  case overlay
  case fullscreen
}

public struct ViewerDrawerLayout: Sendable, Hashable {
  private struct OpenLayout: Sendable, Hashable {
    var content: ViewerContent
    var presentation: ViewerDrawerPresentation
  }

  private var openLayout: OpenLayout?
  private var opensInOverlay: Bool

  public static let closed = Self()

  public var content: ViewerContent? { openLayout?.content }
  public var presentation: ViewerDrawerPresentation? { openLayout?.presentation }
  public var isOpen: Bool { openLayout != nil }

  public init() {
    openLayout = nil
    opensInOverlay = false
  }

  public mutating func open(_ content: ViewerContent) {
    guard openLayout != nil else {
      openLayout = OpenLayout(content: content, presentation: opensInOverlay ? .overlay : .inline)
      opensInOverlay = false
      return
    }
    openLayout?.content = content
  }

  public mutating func close() {
    guard let current = openLayout else { return }
    opensInOverlay = current.presentation == .overlay
    openLayout = nil
  }

  public mutating func setPresentation(_ presentation: ViewerDrawerPresentation) {
    openLayout?.presentation = presentation
  }
}

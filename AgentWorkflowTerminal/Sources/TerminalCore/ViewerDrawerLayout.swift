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

public enum ViewerDrawerSplitAxis: Sendable, Hashable {
  case horizontal
  case vertical
}

public struct ViewerDrawerLayout: Sendable, Hashable {
  private struct OpenLayout: Sendable, Hashable {
    var primary: ViewerContent
    var secondary: ViewerContent?
    var presentation: ViewerDrawerPresentation
  }

  private var openLayout: OpenLayout?
  private var opensInOverlay: Bool
  public private(set) var splitAxis: ViewerDrawerSplitAxis

  public static let closed = Self()

  public var primary: ViewerContent? { openLayout?.primary }
  public var secondary: ViewerContent? { openLayout?.secondary }
  public var presentation: ViewerDrawerPresentation? { openLayout?.presentation }
  public var isOpen: Bool { openLayout != nil }

  public init(splitAxis: ViewerDrawerSplitAxis = .horizontal) {
    openLayout = nil
    opensInOverlay = false
    self.splitAxis = splitAxis
  }

  public mutating func openPrimary(_ content: ViewerContent) {
    guard var current = openLayout else {
      let presentation: ViewerDrawerPresentation = opensInOverlay ? .overlay : .inline
      opensInOverlay = false
      openLayout = OpenLayout(
        primary: content,
        secondary: nil,
        presentation: presentation
      )
      return
    }
    if current.secondary == content {
      current.secondary = current.primary
    }
    current.primary = content
    openLayout = current
  }

  public mutating func openSecondary(_ content: ViewerContent) {
    guard var current = openLayout else {
      let presentation: ViewerDrawerPresentation = opensInOverlay ? .overlay : .inline
      opensInOverlay = false
      openLayout = OpenLayout(
        primary: content,
        secondary: nil,
        presentation: presentation
      )
      return
    }
    if current.primary == content {
      guard let secondary = current.secondary else { return }
      current.primary = secondary
    }
    current.secondary = content
    openLayout = current
  }

  public mutating func closePrimary() {
    guard let current = openLayout else { return }
    guard let secondary = current.secondary else {
      opensInOverlay = current.presentation == .overlay
      openLayout = nil
      return
    }
    openLayout = OpenLayout(
      primary: secondary,
      secondary: nil,
      presentation: current.presentation
    )
  }

  public mutating func closeSecondary() {
    openLayout?.secondary = nil
  }

  public mutating func closeAll() {
    guard let current = openLayout else { return }
    opensInOverlay = current.presentation == .overlay
    openLayout = nil
  }

  public mutating func setPresentation(_ presentation: ViewerDrawerPresentation) {
    openLayout?.presentation = presentation
  }

  public mutating func toggleSplitAxis() {
    splitAxis = splitAxis == .horizontal ? .vertical : .horizontal
  }

  public mutating func swapPanes() {
    guard var current = openLayout, let secondary = current.secondary else { return }
    current.secondary = current.primary
    current.primary = secondary
    openLayout = current
  }
}

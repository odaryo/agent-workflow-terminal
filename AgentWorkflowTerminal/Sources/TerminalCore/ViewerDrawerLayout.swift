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
  public private(set) var content: ViewerContent?
  public private(set) var presentation: ViewerDrawerPresentation?
  private var opensInOverlay: Bool

  public static let closed = Self()

  public var isOpen: Bool { content != nil }

  public init() {
    content = nil
    presentation = nil
    opensInOverlay = false
  }

  public mutating func open(_ content: ViewerContent) {
    if !isOpen {
      presentation = opensInOverlay ? .overlay : .inline
      opensInOverlay = false
    }
    self.content = content
  }

  public mutating func close() {
    guard isOpen else { return }
    opensInOverlay = presentation == .overlay
    content = nil
    presentation = nil
  }

  public mutating func setPresentation(_ presentation: ViewerDrawerPresentation) {
    guard isOpen else { return }
    self.presentation = presentation
  }
}

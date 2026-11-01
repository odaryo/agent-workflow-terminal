public enum ViewerContent: Sendable, Hashable, CaseIterable {
  case code
  case diff
  case evidence
}

public struct ViewerDrawerLayout: Sendable, Hashable {
  public private(set) var content: ViewerContent?
  public private(set) var arrangements: ViewerContentArrangements

  public static let closed = Self()

  public var isOpen: Bool { content != nil }

  public init() {
    self.init(arrangements: .defaults)
  }

  public init(arrangements: ViewerContentArrangements) {
    content = nil
    self.arrangements = arrangements
  }

  public mutating func open(_ content: ViewerContent) {
    self.content = content
  }

  public mutating func close() {
    content = nil
  }

  public func arrangement(for content: ViewerContent) -> ViewerContentArrangement? {
    switch content {
    case .code: arrangements.code
    case .diff: arrangements.diff
    case .evidence: nil
    }
  }

  public mutating func setArrangement(
    _ arrangement: ViewerContentArrangement, for content: ViewerContent
  ) {
    switch content {
    case .code: arrangements.code = arrangement
    case .diff: arrangements.diff = arrangement
    case .evidence: break
    }
  }
}

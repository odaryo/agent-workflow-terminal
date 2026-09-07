public enum FileBrowserChildKind: Int, Sendable, Hashable {
  case directory
  case file
}

public struct FileBrowserChild: Sendable, Hashable {
  public let name: String
  public let kind: FileBrowserChildKind

  public init(name: String, kind: FileBrowserChildKind) {
    self.name = name
    self.kind = kind
  }
}

extension Sequence where Element == FileBrowserChild {
  public func fileBrowserSorted() -> [FileBrowserChild] {
    sorted { lhs, rhs in
      if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
      let lhsFolded = lhs.name.lowercased()
      let rhsFolded = rhs.name.lowercased()
      if lhsFolded != rhsFolded { return lhsFolded < rhsFolded }
      return lhs.name < rhs.name
    }
  }
}

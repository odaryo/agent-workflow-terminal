public enum GitBranchRef: Sendable, Hashable {
  case local(String)
  case remote(String)

  public var shortName: String {
    switch self {
    case .local(let name), .remote(let name): name
    }
  }

  public var fullName: String {
    switch self {
    case .local(let name): "refs/heads/" + name
    case .remote(let name): "refs/remotes/" + name
    }
  }

  public init?(fullName: String) {
    if fullName.hasPrefix("refs/heads/") {
      let name = String(fullName.dropFirst("refs/heads/".count))
      guard !name.isEmpty else { return nil }
      self = .local(name)
    } else if fullName.hasPrefix("refs/remotes/") {
      let name = String(fullName.dropFirst("refs/remotes/".count))
      guard !name.isEmpty, !name.hasSuffix("/HEAD") else { return nil }
      self = .remote(name)
    } else {
      return nil
    }
  }
}

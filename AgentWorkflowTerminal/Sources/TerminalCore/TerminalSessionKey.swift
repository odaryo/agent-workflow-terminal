public struct TerminalSessionKey: Sendable, Hashable {
  public let identity: WorktreeIdentity
  public let index: Int

  public init?(identity: WorktreeIdentity, index: Int) {
    guard (1...9999).contains(index) else { return nil }
    self.identity = identity
    self.index = index
  }

  private init(primary identity: WorktreeIdentity) {
    self.identity = identity
    self.index = 1
  }

  public static func primary(_ identity: WorktreeIdentity) -> Self {
    Self(primary: identity)
  }
}

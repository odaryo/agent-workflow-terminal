public enum TmuxListPanesParseError: Error, Sendable, Equatable {
  case invalidFieldCount(actual: Int)
  case invalidPaneID(String)
  case invalidWindowIndex(String)
  case invalidWindowID(String)
  case invalidPaneIndex(String)
  case invalidPanePID(String)
  case invalidPaneActive(String)
  case invalidPaneDead(String)
  case invalidPaneDeadStatus(String)
  case invalidPaneTermination(status: String, signal: String)
  case invalidSessionNameEscape(String)
  case invalidRawFieldEscape(String)
}

public struct TmuxListPanesParseFailure: Error, Sendable, Equatable {
  public let lineNumber: Int
  public let line: String
  public let error: TmuxListPanesParseError

  public init(lineNumber: Int, line: String, error: TmuxListPanesParseError) {
    self.lineNumber = lineNumber
    self.line = line
    self.error = error
  }
}

public struct TmuxListPanesParseResult: Sendable, Equatable {
  public let panes: [TmuxPane]
  public let failures: [TmuxListPanesParseFailure]

  public init(panes: [TmuxPane], failures: [TmuxListPanesParseFailure]) {
    self.panes = panes
    self.failures = failures
  }
}

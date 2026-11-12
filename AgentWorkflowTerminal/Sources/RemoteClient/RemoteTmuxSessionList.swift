import Foundation

public struct RemoteTmuxSession: Sendable, Equatable, Identifiable {
  public let id: String
  public let attachedClients: Int
  public let name: String

  public init(id: String, attachedClients: Int, name: String) {
    self.id = id
    self.attachedClients = attachedClients
    self.name = name
  }
}

public enum RemoteTmuxSessionListParseError: Error, Sendable, Equatable {
  case missingFields
  case invalidSessionID(String)
  case invalidAttachedClients(String)
}

public struct RemoteTmuxSessionListParseFailure: Sendable, Equatable {
  public let lineNumber: Int
  public let line: String
  public let error: RemoteTmuxSessionListParseError

  public init(lineNumber: Int, line: String, error: RemoteTmuxSessionListParseError) {
    self.lineNumber = lineNumber
    self.line = line
    self.error = error
  }
}

public struct RemoteTmuxSessionListParseResult: Sendable, Equatable {
  public func session(named: String) -> RemoteTmuxSession? {
    sessions.first { $0.name.utf8.elementsEqual(named.utf8) }
  }

  public let sessions: [RemoteTmuxSession]
  public let failures: [RemoteTmuxSessionListParseFailure]

  public init(sessions: [RemoteTmuxSession], failures: [RemoteTmuxSessionListParseFailure]) {
    self.sessions = sessions
    self.failures = failures
  }
}

public enum RemoteTmuxSessionList {
  public static func parse(
    line: String
  ) throws(RemoteTmuxSessionListParseError) -> RemoteTmuxSession {
    let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
    guard fields.count == 3 else { throw .missingFields }
    let id = String(fields[0])
    guard id.first == "$", isDecimal(id.dropFirst()) else { throw .invalidSessionID(id) }
    let clients = String(fields[1])
    guard isDecimal(clients[...]), let attachedClients = Int(clients) else {
      throw .invalidAttachedClients(clients)
    }
    // #806 計測2 (tmux 3.8): \ は出力で二重になる。名前の照合には出力のままの表記を使う。
    return RemoteTmuxSession(id: id, attachedClients: attachedClients, name: String(fields[2]))
  }

  public static func parse(output: String) -> RemoteTmuxSessionListParseResult {
    guard !output.isEmpty else { return .init(sessions: [], failures: []) }
    var lines = output.components(separatedBy: "\n")
    if output.last == "\n" { lines.removeLast() }
    var sessions: [RemoteTmuxSession] = []
    var failures: [RemoteTmuxSessionListParseFailure] = []
    for (index, line) in lines.enumerated() {
      do {
        sessions.append(try parse(line: line))
      } catch {
        failures.append(.init(lineNumber: index + 1, line: line, error: error))
      }
    }
    return .init(sessions: sessions, failures: failures)
  }

  public enum Outcome: Sendable, Equatable {
    case sessions(RemoteTmuxSessionListParseResult)
    case noServer
    case failed(exitStatus: Int?, message: String)
  }

  public static func outcome(exitStatus: Int?, stdout: String, stderr: String) -> Outcome {
    if exitStatus == 0 { return .sessions(parse(output: stdout)) }
    let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    if exitStatus == 1,
      message.hasPrefix("no server running on ")
        || (message.hasPrefix("error connecting to ")
          && message.hasSuffix(" (No such file or directory)"))
    {
      return .noServer
    }
    return .failed(exitStatus: exitStatus, message: message)
  }

  private static func isDecimal(_ value: Substring) -> Bool {
    !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
  }
}

import Foundation

public struct RemoteHostSettings: Sendable, Equatable, Codable {
  public var host: String
  public var port: Int
  public var user: String
  public var tmuxPath: String

  public init(host: String, port: Int, user: String, tmuxPath: String) {
    self.host = host
    self.port = port
    self.user = user
    self.tmuxPath = tmuxPath
  }

  public enum Problem: Sendable, Equatable {
    case hostHasSurroundingWhitespace
    case userHasSurroundingWhitespace
    case emptyHost
    case portOutOfRange
    case emptyUser
    case tmuxPathNotAbsolute
  }

  public var problems: [Problem] {
    var problems: [Problem] = []
    let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedHost.isEmpty {
      problems.append(.emptyHost)
    } else if trimmedHost != host {
      problems.append(.hostHasSurroundingWhitespace)
    }
    if !(1...65535).contains(port) { problems.append(.portOutOfRange) }
    let trimmedUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedUser.isEmpty {
      problems.append(.emptyUser)
    } else if trimmedUser != user {
      problems.append(.userHasSurroundingWhitespace)
    }
    if !tmuxPath.hasPrefix("/") { problems.append(.tmuxPathNotAbsolute) }
    return problems
  }
}

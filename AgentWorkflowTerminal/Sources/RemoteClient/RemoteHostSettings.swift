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
    case emptyHost
    case portOutOfRange
    case emptyUser
    case tmuxPathNotAbsolute
  }

  public var problems: [Problem] {
    var problems: [Problem] = []
    if host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { problems.append(.emptyHost) }
    if !(1...65535).contains(port) { problems.append(.portOutOfRange) }
    if user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { problems.append(.emptyUser) }
    if !tmuxPath.hasPrefix("/") { problems.append(.tmuxPathNotAbsolute) }
    return problems
  }
}

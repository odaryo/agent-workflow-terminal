import Foundation

public enum HostControlRequest: Sendable, Equatable {
  case openWorktree(directory: String)
}

public struct HostControlOpenedWorktree: Sendable, Equatable {
  public var session: String
  public var directory: String
  public var created: Bool
  public var agentCommand: String?

  public init(session: String, directory: String, created: Bool, agentCommand: String?) {
    self.session = session
    self.directory = directory
    self.created = created
    self.agentCommand = agentCommand
  }
}

public enum HostControlFailureCode: String, Sendable, Equatable, CaseIterable {
  case invalidRequest = "invalid_request"
  case notRegistered = "not_registered"
  case projectRoot = "project_root"
  case unreachable = "unreachable"
  case tmuxFailed = "tmux_failed"
}

public enum HostControlResponse: Sendable, Equatable {
  case opened(HostControlOpenedWorktree)
  case failure(code: HostControlFailureCode, message: String)
}

public enum HostControlProtocol {
  public static let version = 1

  public static func encode(_ request: HostControlRequest) -> String {
    switch request {
    case .openWorktree(let directory):
      return encodeObject(["command": "worktree.open", "directory": directory, "version": version])
    }
  }

  public static func decodeRequest(
    _ line: String
  ) -> Result<HostControlRequest, HostControlProtocolError> {
    do {
      let wire = try JSONDecoder().decode(RequestWire.self, from: Data(line.utf8))
      guard try hasIntegerVersion(line) else {
        return .failure(HostControlProtocolError(message: "要求のJSON形式が不正です"))
      }
      guard wire.version == version, wire.command == "worktree.open" else {
        return .failure(HostControlProtocolError(message: "未対応のcommandまたはversionです"))
      }
      return .success(.openWorktree(directory: wire.directory))
    } catch {
      return .failure(HostControlProtocolError(message: "要求のJSON形式が不正です"))
    }
  }

  public static func encode(_ response: HostControlResponse) -> String {
    switch response {
    case .opened(let worktree):
      return encodeObject([
        "version": version, "ok": true, "session": worktree.session,
        "directory": worktree.directory, "created": worktree.created,
        "agentCommand": worktree.agentCommand.map { $0 as Any } ?? NSNull(),
      ])
    case .failure(let code, let message):
      return encodeObject([
        "version": version, "ok": false, "code": code.rawValue, "message": message,
      ])
    }
  }

  public static func decodeResponse(
    _ line: String
  ) -> Result<HostControlResponse, HostControlProtocolError> {
    do {
      let wire = try JSONDecoder().decode(ResponseWire.self, from: Data(line.utf8))
      guard try hasIntegerVersion(line) else {
        return .failure(HostControlProtocolError(message: "応答のJSON形式が不正です"))
      }
      return .success(wire.response)
    } catch let error as HostControlProtocolError {
      return .failure(error)
    } catch {
      return .failure(HostControlProtocolError(message: "応答のJSON形式が不正です"))
    }
  }

  private static func hasIntegerVersion(_ line: String) throws -> Bool {
    // JSONDecoderは1.0や1e0もIntへ変換するため、検証済みJSONの元の数値表記を確認する。
    let expression = try NSRegularExpression(
      pattern: #""(?:\\.|[^"\\])*"|[{}\[\],:]|[^\s{}\[\],:]+"#)
    let tokens = expression.matches(in: line, range: NSRange(line.startIndex..., in: line))
      .compactMap { match in Range(match.range, in: line).map { String(line[$0]) } }
    var depth = 0
    var found = false
    for (index, token) in tokens.enumerated() {
      switch token {
      case "{", "[": depth += 1
      case "}", "]": depth -= 1
      default:
        guard depth == 1, index + 2 < tokens.count, tokens[index + 1] == ":",
          token.hasPrefix("\""),
          try JSONDecoder().decode(String.self, from: Data(token.utf8)) == "version"
        else { continue }
        guard tokens[index + 2] == "1" else { return false }
        found = true
      }
    }
    return found
  }

  private static func encodeObject(_ object: [String: Any]) -> String {
    // 呼び出し元はJSONで表現できる文字列・整数・真偽値・nullだけを構築する。
    let data = try? JSONSerialization.data(
      withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    return String(decoding: data ?? Data(), as: UTF8.self)
  }

  private struct RequestWire: Decodable {
    let version: Int
    let command: String
    let directory: String
  }

  private struct ResponseWire: Decodable {
    let response: HostControlResponse

    private enum CodingKeys: String, CodingKey {
      case version, ok, session, directory, created, agentCommand, code, message
    }

    init(from decoder: any Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      guard try values.decode(Int.self, forKey: .version) == HostControlProtocol.version else {
        throw HostControlProtocolError(message: "未対応のversionです")
      }
      if try values.decode(Bool.self, forKey: .ok) {
        response = .opened(
          HostControlOpenedWorktree(
            session: try values.decode(String.self, forKey: .session),
            directory: try values.decode(String.self, forKey: .directory),
            created: try values.decode(Bool.self, forKey: .created),
            agentCommand: try values.decode(String?.self, forKey: .agentCommand)))
      } else {
        let rawCode = try values.decode(String.self, forKey: .code)
        guard let code = HostControlFailureCode(rawValue: rawCode) else {
          throw HostControlProtocolError(message: "未対応の失敗コードです")
        }
        response = .failure(code: code, message: try values.decode(String.self, forKey: .message))
      }
    }
  }
}

public struct HostControlProtocolError: Error, Sendable, Equatable {
  public var message: String

  public init(message: String) {
    self.message = message
  }
}

public enum HostControlCommand: Sendable, Equatable {
  case openWorktree(directory: String, socket: String?)
}

public enum HostControlCommandLine {
  /// `arguments` はプログラム名を含まない。
  public static func parse(
    _ arguments: [String]
  ) -> Result<HostControlCommand, HostControlProtocolError> {
    guard arguments.starts(with: ["worktree", "open"]) else {
      return .failure(HostControlProtocolError(message: "worktree openを指定してください"))
    }
    var directory: String?
    var socket: String?
    var index = 2
    while index < arguments.count {
      let option = arguments[index]
      guard index + 1 < arguments.count else {
        return .failure(HostControlProtocolError(message: "引数の値がありません: \(option)"))
      }
      let value = arguments[index + 1]
      guard !value.isEmpty, !value.hasPrefix("--") else {
        return .failure(HostControlProtocolError(message: "不正な引数の値です: \(option)"))
      }
      switch option {
      case "--directory" where directory == nil: directory = value
      case "--socket" where socket == nil: socket = value
      default:
        return .failure(HostControlProtocolError(message: "不正な引数です: \(option)"))
      }
      index += 2
    }
    guard let directory else {
      return .failure(HostControlProtocolError(message: "--directoryが必要です"))
    }
    return .success(.openWorktree(directory: directory, socket: socket))
  }
}

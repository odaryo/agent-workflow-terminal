import Foundation

public enum HostControlRequest: Sendable, Equatable {
  case openWorktree(directory: String, fromPane: PaneID? = nil, purpose: String? = nil)
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
    case .openWorktree(let directory, let fromPane, let purpose):
      var object: [String: Any] = [
        "command": "worktree.open", "directory": directory, "version": version,
      ]
      // 省くのは、古いhostctlが送る要求と同じバイト列に保つため。
      if let fromPane { object["fromPane"] = fromPane.rawValue }
      if let purpose { object["purpose"] = purpose }
      return encodeObject(object)
    }
  }

  public static func decodeRequest(
    _ line: String
  ) -> Result<HostControlRequest, HostControlProtocolError> {
    do {
      let wire = try JSONDecoder().decode(RequestWire.self, from: Data(line.utf8))
      guard wire.version == version, wire.command == "worktree.open" else {
        return .failure(HostControlProtocolError(message: "未対応のcommandまたはversionです"))
      }
      // fromPaneは別に読む。同じwireで読むと、文字列でない値が総称のJSON形式の誤りになり、
      // どの項目が不正かを示せない。
      let fromPane: PaneID?
      do {
        fromPane = try JSONDecoder().decode(FromPaneWire.self, from: Data(line.utf8)).fromPane
      } catch {
        return .failure(invalidFromPane)
      }
      // 中身 (長さ・改行・末尾の`;`) は検査しない。上限はAdaptersにあり、アプリがセッションを
      // 作る前に検査する。
      let purpose: String?
      do {
        purpose = try JSONDecoder().decode(PurposeWire.self, from: Data(line.utf8)).purpose
      } catch {
        return .failure(invalidPurpose)
      }
      return .success(
        .openWorktree(directory: wire.directory, fromPane: fromPane, purpose: purpose))
    } catch {
      return .failure(HostControlProtocolError(message: "要求のJSON形式が不正です"))
    }
  }

  static let invalidFromPane = HostControlProtocolError(message: "fromPaneの形式が不正です")
  static let invalidPurpose = HostControlProtocolError(message: "purposeの形式が不正です")

  /// tmux の `#{pane_id}` の形 (`%` と ASCII の10進数字) だけを受け付ける。要求の `fromPane` と
  /// `--from-pane` で共有する。
  static func callerPane(_ value: String) -> PaneID? {
    let bytes = Array(value.utf8)
    guard bytes.count >= 2, bytes[0] == UInt8(ascii: "%"),
      bytes.dropFirst().allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) })
    else { return nil }
    return PaneID(rawValue: value)
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
      return .success(wire.response)
    } catch let error as HostControlProtocolError {
      return .failure(error)
    } catch {
      return .failure(HostControlProtocolError(message: "応答のJSON形式が不正です"))
    }
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

  private struct FromPaneWire: Decodable {
    let fromPane: PaneID?

    private enum CodingKeys: String, CodingKey {
      case fromPane
    }

    init(from decoder: any Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      guard let raw = try values.decodeIfPresent(String.self, forKey: .fromPane) else {
        fromPane = nil
        return
      }
      guard let pane = HostControlProtocol.callerPane(raw) else {
        throw HostControlProtocol.invalidFromPane
      }
      fromPane = pane
    }
  }

  private struct PurposeWire: Decodable {
    let purpose: String?
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
  case openWorktree(directory: String, socket: String?, fromPane: PaneID?, purpose: String?)
}

public enum HostControlCommandLine {
  /// `arguments` はプログラム名を含まない。
  public static func parse(
    _ arguments: [String]
  ) -> Result<HostControlCommand, HostControlProtocolError> {
    guard arguments.starts(with: ["worktree", "open"]) else {
      return .failure(HostControlProtocolError(message: "worktree openを指定してください"))
    }
    var options = Options()
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
      if let error = options.assign(option, value) { return .failure(error) }
      index += 2
    }
    guard let directory = options.directory else {
      return .failure(HostControlProtocolError(message: "--directoryが必要です"))
    }
    return .success(
      .openWorktree(
        directory: directory, socket: options.socket, fromPane: options.fromPane,
        purpose: options.purpose))
  }

  private struct Options {
    var directory: String?
    var socket: String?
    var fromPane: PaneID?
    var purpose: String?

    /// 2回目の指定と未知の引数は同じ「不正な引数です」にする。
    mutating func assign(_ option: String, _ value: String) -> HostControlProtocolError? {
      switch option {
      case "--directory" where directory == nil: directory = value
      case "--socket" where socket == nil: socket = value
      case "--from-pane" where fromPane == nil:
        guard let pane = HostControlProtocol.callerPane(value) else {
          return HostControlProtocolError(message: "不正な引数の値です: \(option)")
        }
        fromPane = pane
      // handoff.sh は exit 2 を「--purpose を知らない古い hostctl」と読んで目的なしで呼び直すので、
      // 中身を理由に拒否しない。中身はアプリがセッションを作る前に検査する。
      case "--purpose" where purpose == nil: purpose = value
      default:
        return HostControlProtocolError(message: "不正な引数です: \(option)")
      }
      return nil
    }
  }
}

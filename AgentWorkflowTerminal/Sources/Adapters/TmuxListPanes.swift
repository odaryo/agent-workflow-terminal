import Foundation
import TerminalCore

public struct TmuxPane: Sendable, Hashable, Codable {
  public let paneID: PaneID
  public let sessionName: String
  public let windowIndex: Int
  public let windowID: String
  public let paneIndex: Int
  public let panePID: Int32
  public let isActive: Bool
  public let currentCommand: String

  public init(
    paneID: PaneID,
    sessionName: String,
    windowIndex: Int,
    windowID: String,
    paneIndex: Int,
    panePID: Int32,
    isActive: Bool,
    currentCommand: String
  ) {
    self.paneID = paneID
    self.sessionName = sessionName
    self.windowIndex = windowIndex
    self.windowID = windowID
    self.paneIndex = paneIndex
    self.panePID = panePID
    self.isActive = isActive
    self.currentCommand = currentCommand
  }
}

public enum TmuxListPanesParseError: Error, Sendable, Equatable {
  case invalidFieldCount(actual: Int)
  case invalidVisEscape(fieldNumber: Int, value: String, byteOffset: Int)
  case invalidUTF8(fieldNumber: Int, value: String)
  case invalidPaneID(String)
  case invalidWindowIndex(String)
  case invalidWindowID(String)
  case invalidPaneIndex(String)
  case invalidPanePID(String)
  case invalidPaneActive(String)
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

public enum TmuxListPanes {
  private static let formatSeparator = "\u{1F}"
  private static let encodedSeparator: [UInt8] = [0x5C, 0x30, 0x33, 0x37]

  /// 生の Unit Separator を渡す一方で出力側の `\037` を境界にするのは、非 control-mode の
  /// stdout では tmux の `format_draw` が `utf8_stravisx` を
  /// `VIS_OCTAL | VIS_CSTYLE | VIS_TAB | VIS_NL` で呼ぶため。control-mode の入力には使わない。
  public static let format = [
    "#{pane_id}",
    "#{session_name}",
    "#{window_index}",
    "#{window_id}",
    "#{pane_index}",
    "#{pane_pid}",
    "#{pane_active}",
    "#{pane_current_command}",
  ].joined(separator: formatSeparator)

  public static func parse(line: String) throws(TmuxListPanesParseError) -> TmuxPane {
    let encodedFields = splitEncodedFields(line)
    guard encodedFields.count == 8 else {
      throw .invalidFieldCount(actual: encodedFields.count)
    }
    var fields: [String] = []
    for (index, field) in encodedFields.enumerated() {
      fields.append(try unescapeVis(field, fieldNumber: index + 1))
    }

    guard fields[0].first == "%", Int(fields[0].dropFirst()) != nil else {
      throw .invalidPaneID(fields[0])
    }
    guard let windowIndex = Int(fields[2]), windowIndex >= 0 else {
      throw .invalidWindowIndex(fields[2])
    }
    guard fields[3].first == "@", Int(fields[3].dropFirst()) != nil else {
      throw .invalidWindowID(fields[3])
    }
    guard let paneIndex = Int(fields[4]), paneIndex >= 0 else {
      throw .invalidPaneIndex(fields[4])
    }
    guard let panePID = Int32(fields[5]), panePID > 0 else {
      throw .invalidPanePID(fields[5])
    }

    let isActive: Bool
    switch fields[6] {
    case "0": isActive = false
    case "1": isActive = true
    default: throw .invalidPaneActive(fields[6])
    }

    return TmuxPane(
      paneID: PaneID(rawValue: fields[0]),
      sessionName: fields[1],
      windowIndex: windowIndex,
      windowID: fields[3],
      paneIndex: paneIndex,
      panePID: panePID,
      isActive: isActive,
      currentCommand: fields[7]
    )
  }

  /// 非 control-mode の `tmux list-panes -F format` stdout 専用。tmux はレコードを LF で
  /// 終端し、各レコード全体を上記の vis flags で符号化するため、他の改行文字では分割しない。
  public static func parse(output: String) -> TmuxListPanesParseResult {
    guard !output.isEmpty else {
      return TmuxListPanesParseResult(panes: [], failures: [])
    }

    var lines = output.components(separatedBy: "\n")
    if output.last == "\n" {
      lines.removeLast()
    }

    var panes: [TmuxPane] = []
    var failures: [TmuxListPanesParseFailure] = []
    for (index, line) in lines.enumerated() {
      do {
        panes.append(try parse(line: line))
      } catch {
        failures.append(
          TmuxListPanesParseFailure(lineNumber: index + 1, line: line, error: error)
        )
      }
    }
    return TmuxListPanesParseResult(panes: panes, failures: failures)
  }

  private static func splitEncodedFields(_ line: String) -> [String] {
    let bytes = Array(line.utf8)
    var fields: [String] = []
    var fieldStart = 0
    var index = 0

    while index < bytes.count {
      guard bytes[index] == 0x5C else {
        index += 1
        continue
      }
      if index + 1 < bytes.count, bytes[index + 1] == 0x5C {
        index += 2
        continue
      }
      if bytes[index...].starts(with: encodedSeparator) {
        fields.append(String(decoding: bytes[fieldStart..<index], as: UTF8.self))
        index += encodedSeparator.count
        fieldStart = index
        continue
      }
      index += 1
    }

    fields.append(String(decoding: bytes[fieldStart...], as: UTF8.self))
    return fields
  }

  private static func unescapeVis(
    _ value: String,
    fieldNumber: Int
  ) throws(TmuxListPanesParseError) -> String {
    let bytes = Array(value.utf8)
    var decoded: [UInt8] = []
    var index = 0

    while index < bytes.count {
      guard bytes[index] == 0x5C else {
        decoded.append(bytes[index])
        index += 1
        continue
      }

      let escapeOffset = index
      index += 1
      guard index < bytes.count else {
        throw .invalidVisEscape(fieldNumber: fieldNumber, value: value, byteOffset: escapeOffset)
      }

      switch bytes[index] {
      case 0x5C:
        decoded.append(0x5C)
        index += 1
      case 0x61:
        decoded.append(0x07)
        index += 1
      case 0x62:
        decoded.append(0x08)
        index += 1
      case 0x65, 0x45:
        decoded.append(0x1B)
        index += 1
      case 0x66:
        decoded.append(0x0C)
        index += 1
      case 0x6E:
        decoded.append(0x0A)
        index += 1
      case 0x72:
        decoded.append(0x0D)
        index += 1
      case 0x73:
        decoded.append(0x20)
        index += 1
      case 0x74:
        decoded.append(0x09)
        index += 1
      case 0x76:
        decoded.append(0x0B)
        index += 1
      case 0x30...0x37:
        var octalValue: UInt8 = 0
        var digitCount = 0
        while index < bytes.count, digitCount < 3, (0x30...0x37).contains(bytes[index]) {
          octalValue = octalValue &* 8 &+ (bytes[index] - 0x30)
          index += 1
          digitCount += 1
        }
        decoded.append(octalValue)
      case 0x4D:
        guard index + 2 < bytes.count else {
          throw .invalidVisEscape(fieldNumber: fieldNumber, value: value, byteOffset: escapeOffset)
        }
        let marker = bytes[index + 1]
        let character = bytes[index + 2]
        switch marker {
        case 0x2D:
          decoded.append(character | 0x80)
        case 0x5E:
          guard let control = controlCharacter(for: character) else {
            throw .invalidVisEscape(
              fieldNumber: fieldNumber, value: value, byteOffset: escapeOffset)
          }
          decoded.append(control | 0x80)
        default:
          throw .invalidVisEscape(fieldNumber: fieldNumber, value: value, byteOffset: escapeOffset)
        }
        index += 3
      case 0x5E:
        guard index + 1 < bytes.count,
          let control = controlCharacter(for: bytes[index + 1])
        else {
          throw .invalidVisEscape(fieldNumber: fieldNumber, value: value, byteOffset: escapeOffset)
        }
        decoded.append(control)
        index += 2
      default:
        throw .invalidVisEscape(fieldNumber: fieldNumber, value: value, byteOffset: escapeOffset)
      }
    }

    guard let result = String(bytes: decoded, encoding: .utf8) else {
      throw .invalidUTF8(fieldNumber: fieldNumber, value: value)
    }
    return result
  }

  private static func controlCharacter(for byte: UInt8) -> UInt8? {
    if byte == 0x3F {
      return 0x7F
    }
    guard (0x40...0x5F).contains(byte) else {
      return nil
    }
    return byte & 0x1F
  }
}

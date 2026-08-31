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
  case invalidPaneID(String)
  case invalidWindowIndex(String)
  case invalidWindowID(String)
  case invalidPaneIndex(String)
  case invalidPanePID(String)
  case invalidPaneActive(String)
}

public enum TmuxListPanes {
  // 空白・タブ・一般的な記号を区切りに使わないのは、session 名や実行コマンドにも
  // 現れ得るため。Unit Separator は tmux 3.4 の出力では4文字の `\037` に可視化される。
  private static let formatSeparator = "\u{1F}"
  private static let outputSeparator = "\\037"

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

  public static func parse(line: String) throws -> TmuxPane {
    let fields = line.components(separatedBy: outputSeparator)
    guard fields.count == 8 else {
      throw TmuxListPanesParseError.invalidFieldCount(actual: fields.count)
    }

    guard fields[0].first == "%", Int(fields[0].dropFirst()) != nil else {
      throw TmuxListPanesParseError.invalidPaneID(fields[0])
    }
    guard let windowIndex = Int(fields[2]), windowIndex >= 0 else {
      throw TmuxListPanesParseError.invalidWindowIndex(fields[2])
    }
    guard fields[3].first == "@", Int(fields[3].dropFirst()) != nil else {
      throw TmuxListPanesParseError.invalidWindowID(fields[3])
    }
    guard let paneIndex = Int(fields[4]), paneIndex >= 0 else {
      throw TmuxListPanesParseError.invalidPaneIndex(fields[4])
    }
    guard let panePID = Int32(fields[5]), panePID > 0 else {
      throw TmuxListPanesParseError.invalidPanePID(fields[5])
    }

    let isActive: Bool
    switch fields[6] {
    case "0": isActive = false
    case "1": isActive = true
    default: throw TmuxListPanesParseError.invalidPaneActive(fields[6])
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

  public static func parse(output: String) throws -> [TmuxPane] {
    try output.split(whereSeparator: \.isNewline).map {
      try parse(line: String($0))
    }
  }
}

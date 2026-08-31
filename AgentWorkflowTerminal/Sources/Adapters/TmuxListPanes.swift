import Foundation
import TerminalCore

public struct TmuxPane: Sendable, Hashable, Codable {
  /// tmux `#{pane_id}` の `%N` 形式を、pane 指定に再利用できるよう変更せず保持する。
  public let paneID: PaneID
  /// tmux `#{session_name}` が返す生成時符号化済みの正式名。`-t` へそのまま渡す値であり、
  /// 人間可読形ではない。表示用の復号が必要になった場合は別 API に分離する。
  public let sessionName: String
  /// tmux `#{window_index}` を非負整数へ変換した値。
  public let windowIndex: Int
  /// tmux `#{window_id}` の `@N` 形式を、window 指定に再利用できるよう変更せず保持する。
  public let windowID: String
  /// tmux `#{pane_index}` を非負整数へ変換した値。
  public let paneIndex: Int
  /// tmux `#{pane_pid}` を正のプロセス ID へ変換した値。
  public let panePID: Int32
  /// tmux `#{pane_active}` の `0` / `1` だけを Bool へ変換した値。
  public let isActive: Bool
  /// tmux `#{pane_current_command}` の生値。名前フィールドと異なり `\`・TAB・LF も
  /// 二重化されないため、表示文字列として復号しない。
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

  /// tmux 3.4 の非 control-mode 実出力では、format に埋めた生の Unit Separator が
  /// `\037` になる一方、展開値の `\`・TAB・LF は一律には符号化されない
  /// (`tmux-3.4-list-panes-session-round-trip.txt` /
  /// `tmux-3.4-list-panes-raw-current-command.txt` で実測)。
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

  /// 1レコード内でもフィールドごとに tmux の文法が異なるため、区切りを除いた文字列を復号しない。
  /// とくに `session_name` は tmux の正式名であり、表示向けの vis 復号対象ではない。
  public static func parse(line: String) throws(TmuxListPanesParseError) -> TmuxPane {
    let fields = splitEncodedFields(line)
    guard fields.count == 8 else {
      throw .invalidFieldCount(actual: fields.count)
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

  /// 非 control-mode の `tmux list-panes -F format` stdout 専用。LF をレコード終端として
  /// 扱うため、生 LF を含む非名前フィールドを既に1レコードへ切り出した場合は `parse(line:)` を使う。
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
      // tmux 3.4 は名前の生成時に `\` を `\\` にするため、名前中のリテラル `\037` は
      // `\\037` となり区切りではない。一方 `pane_current_command` 等の非名前フィールドは
      // 二重化されないので、この走査は値を復号せず byte 列のまま保持する (上記 fixture で実測)。
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
}

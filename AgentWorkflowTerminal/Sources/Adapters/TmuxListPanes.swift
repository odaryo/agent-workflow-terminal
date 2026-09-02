import Foundation
import TerminalCore

public enum TmuxPaneTermination: Sendable, Hashable, Codable {
  case exited(status: Int32)
  case signaled(String)
}

public struct TmuxPane: Sendable, Hashable, Codable {
  /// tmux `#{pane_id}` の `%N` 形式を、pane 指定に再利用できるよう変更せず保持する。
  public let paneID: PaneID
  /// tmux `#{session_name}` が返す生成時符号化済みの正式名。出力時に追加される `$` 用の
  /// バックスラッシュだけを除き、`-t` へそのまま渡せる形で保持する。
  public let sessionName: String
  /// tmux `#{window_index}` を非負整数へ変換した値。
  public let windowIndex: Int
  /// tmux `#{window_id}` の `@N` 形式を、window 指定に再利用できるよう変更せず保持する。
  public let windowID: String
  /// tmux `#{pane_index}` を非負整数へ変換した値。
  public let paneIndex: Int
  /// dead pane でも終了済みプロセスの古い PID が残るため、死活判定には使わない。
  public let panePID: Int32
  /// tmux `#{pane_active}` の `0` / `1` だけを Bool へ変換した値。
  public let isActive: Bool
  public let currentCommand: String
  /// `nil` は live pane を表し、観測失敗はこの型にせず parse failure として分離する。
  public let termination: TmuxPaneTermination?
  public let tty: String
  /// tmux 3.4 は dead pane の値を空文字列にするため、空でも parse failure にしない。
  public let currentPath: String
  public let title: String

  public init(
    paneID: PaneID,
    sessionName: String,
    windowIndex: Int,
    windowID: String,
    paneIndex: Int,
    panePID: Int32,
    isActive: Bool,
    currentCommand: String,
    termination: TmuxPaneTermination?,
    tty: String,
    currentPath: String,
    title: String
  ) {
    self.paneID = paneID
    self.sessionName = sessionName
    self.windowIndex = windowIndex
    self.windowID = windowID
    self.paneIndex = paneIndex
    self.panePID = panePID
    self.isActive = isActive
    self.currentCommand = currentCommand
    self.termination = termination
    self.tty = tty
    self.currentPath = currentPath
    self.title = title
  }

  public var snapshot: PaneSnapshot {
    PaneSnapshot(
      id: paneID,
      processID: panePID,
      tty: tty,
      currentCommand: currentCommand,
      currentPath: currentPath,
      title: title,
      isDead: termination != nil
    )
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
  case invalidPaneDead(String)
  case invalidPaneDeadStatus(String)
  case invalidPaneTermination(status: String, signal: String)
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
  private static let backslash: UInt8 = 0x5C
  private static let dollar: UInt8 = 0x24

  /// tmux 3.4 の非 control-mode 出力では、format に埋めた Unit Separator は `\037` になる。
  /// ユーザーが設定できる生フィールドは置換でバックスラッシュを二重化する。これにより全フィールドが
  /// 「`\\` はリテラル `\`」の文法に従い、区切り走査はフィールド順序に依存しない。
  /// `pane_dead_status` / `pane_dead_signal` は tmux 管理値で、実測値域が空文字列・非負整数・
  /// signal token のため、ユーザー由来の生フィールドと異なり置換を重ねない。
  public static let format = [
    "#{pane_id}",
    "#{session_name}",
    "#{window_index}",
    "#{window_id}",
    "#{pane_index}",
    "#{pane_pid}",
    "#{pane_active}",
    #"#{s/\\/\\\\/:pane_current_command}"#,
    "#{pane_dead}",
    "#{pane_dead_status}",
    "#{pane_dead_signal}",
    #"#{s/\\/\\\\/:pane_tty}"#,
    #"#{s/\\/\\\\/:pane_current_path}"#,
    #"#{s/\\/\\\\/:pane_title}"#,
  ].joined(separator: formatSeparator)

  public static func parse(line: String) throws(TmuxListPanesParseError) -> TmuxPane {
    let encodedFields = splitEncodedFields(line)
    guard encodedFields.count == 14 else {
      throw .invalidFieldCount(actual: encodedFields.count)
    }
    let fields = encodedFields.map(decodeInsertedDollarEscapes)

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
    // tmux 3.4 は dead pane にも終了済みプロセスの PID を残すため、live と同じ値域で受け入れる。
    guard let panePID = Int32(fields[5]), panePID > 0 else {
      throw .invalidPanePID(fields[5])
    }

    let isActive = try parsePaneActive(fields[6])
    let isDead = try parsePaneDead(fields[8])
    let termination = try parseTermination(
      isDead: isDead,
      status: fields[9],
      signal: fields[10]
    )

    return TmuxPane(
      paneID: PaneID(rawValue: fields[0]),
      sessionName: fields[1],
      windowIndex: windowIndex,
      windowID: fields[3],
      paneIndex: paneIndex,
      panePID: panePID,
      isActive: isActive,
      currentCommand: decodeRawField(fields[7]),
      termination: termination,
      tty: decodeRawField(fields[11]),
      currentPath: decodeRawField(fields[12]),
      title: decodeRawField(fields[13])
    )
  }

  /// 非 control-mode の `tmux list-panes -F format` stdout 専用。LF をレコード終端として
  /// 扱うため、生 LF を含むフィールドを既に1レコードへ切り出した場合は `parse(line:)` を使う。
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

  private static func parseTermination(
    isDead: Bool,
    status: String,
    signal: String
  ) throws(TmuxListPanesParseError) -> TmuxPaneTermination? {
    if !isDead {
      guard status.isEmpty, signal.isEmpty else {
        throw .invalidPaneTermination(status: status, signal: signal)
      }
      return nil
    }

    switch (status.isEmpty, signal.isEmpty) {
    case (false, true):
      guard let exitStatus = Int32(status), exitStatus >= 0 else {
        throw .invalidPaneDeadStatus(status)
      }
      return .exited(status: exitStatus)
    case (true, false):
      return .signaled(signal)
    case (true, true), (false, false):
      throw .invalidPaneTermination(status: status, signal: signal)
    }
  }

  private static func parsePaneActive(
    _ field: String
  ) throws(TmuxListPanesParseError) -> Bool {
    switch field {
    case "0": false
    case "1": true
    default: throw .invalidPaneActive(field)
    }
  }

  private static func parsePaneDead(
    _ field: String
  ) throws(TmuxListPanesParseError) -> Bool {
    switch field {
    case "0": false
    case "1": true
    default: throw .invalidPaneDead(field)
    }
  }

  private static func splitEncodedFields(_ line: String) -> [String] {
    let bytes = Array(line.utf8)
    var fields: [String] = []
    var fieldStart = 0
    var index = 0

    while index < bytes.count {
      guard bytes[index] == backslash else {
        index += 1
        continue
      }
      if index + 1 < bytes.count, bytes[index + 1] == backslash {
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

  private static func decodeInsertedDollarEscapes(_ field: String) -> String {
    let bytes = Array(field.utf8)
    var decoded: [UInt8] = []
    decoded.reserveCapacity(bytes.count)
    var index = 0

    while index < bytes.count {
      guard bytes[index] == backslash else {
        decoded.append(bytes[index])
        index += 1
        continue
      }

      var slashEnd = index + 1
      while slashEnd < bytes.count, bytes[slashEnd] == backslash {
        slashEnd += 1
      }
      if slashEnd < bytes.count, bytes[slashEnd] == dollar {
        // 連続列をまとめて扱わないと、リテラル `\\` と `$` 用の追加分が並ぶ `\\\$` を壊す。
        decoded.append(contentsOf: bytes[index..<(slashEnd - 1)])
        decoded.append(dollar)
        index = slashEnd + 1
      } else {
        decoded.append(contentsOf: bytes[index..<slashEnd])
        index = slashEnd
      }
    }

    return String(decoding: decoded, as: UTF8.self)
  }

  private static func decodeRawField(_ field: String) -> String {
    let bytes = Array(field.utf8)
    var decoded: [UInt8] = []
    decoded.reserveCapacity(bytes.count)
    var index = 0

    while index < bytes.count {
      decoded.append(bytes[index])
      if bytes[index] == backslash, index + 1 < bytes.count, bytes[index + 1] == backslash {
        index += 2
      } else {
        index += 1
      }
    }

    return String(decoding: decoded, as: UTF8.self)
  }
}

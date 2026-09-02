import Foundation
import TerminalCore

public struct TmuxPane: Sendable, Hashable, Codable {
  /// tmux `#{pane_id}` の `%N` 形式を、pane 指定に再利用できるよう変更せず保持する。
  public let paneID: PaneID
  /// tmux `#{session_name}` が返す生成時符号化済みの target 文字列。`has-session -t` は
  /// 完全一致が無い場合に glob も試すため、その成功だけでは完全一致を保証できない。
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
  public let termination: ProcessTermination?
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
    termination: ProcessTermination?,
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
      termination: termination
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
  /// command / path / title はユーザー由来の `\037` と区切りを分けるため、tty は生文字列の
  /// 復号規則を統一するため、置換でバックスラッシュを二重化する。名前系は生成時符号化を維持する。
  /// 実測では出力段が `$` の次に ASCII 英字 / `_` / `{` または有効な非 ASCII 文字がある場合だけ
  /// `\` を挿入した。ASCII 0x20...0x7E の全組合せ、末尾・連続 `$`、日本語と絵文字で確認した。
  /// 制御バイトは 0x01...0x06 / 0x0E...0x1F / 0x7F が八進、BEL / BS / VT / FF / CR が
  /// named escape、TAB / LF が生出力だった。単独 0x80...0x9F と不正 UTF-8 は macOS の path と
  /// tmux title が受け付けず、有効な UTF-8 の C1 制御文字は変更されなかった。
  /// リテラル `\` は全フィールドで `\\` となるため通常の区切り走査は順序に依存しないが、出力段が
  /// 実 0x1F を `\037`、LF を生のまま出すため、その値を含む pane は壊れた値を返さず failure にする。
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
    let fields = encodedFields

    guard
      fields[0].first == "%", let paneNumber = Int(fields[0].dropFirst()), paneNumber >= 0
    else {
      throw .invalidPaneID(fields[0])
    }
    guard let windowIndex = Int(fields[2]), windowIndex >= 0 else {
      throw .invalidWindowIndex(fields[2])
    }
    guard
      fields[3].first == "@", let windowNumber = Int(fields[3].dropFirst()), windowNumber >= 0
    else {
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
      paneID: PaneID(rawValue: decodeInsertedDollarEscapes(fields[0])),
      sessionName: decodeInsertedDollarEscapes(fields[1]),
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
  ) throws(TmuxListPanesParseError) -> ProcessTermination? {
    if !isDead {
      // tmux 3.4 の live pane は実測した全件で status / signal とも空だった。
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
      // tmux 3.4 は sig2name の小文字短縮名 (term / hup / kill / segv 等) を返し、
      // 名前が無い環境では十進文字列を返す。
      return .signaled(signal)
    case (true, true):
      // fd close と SIGCHLD 回収の間は、終了済みでも理由がまだ空になり得る。
      return .unknown
    case (false, false):
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
      if slashEnd < bytes.count,
        bytes[slashEnd] == dollar,
        shouldDecodeDollarEscape(bytes: bytes, dollarIndex: slashEnd)
      {
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
      guard bytes[index] == backslash, index + 1 < bytes.count else {
        decoded.append(bytes[index])
        index += 1
        continue
      }

      if bytes[index + 1] == backslash {
        decoded.append(backslash)
        index += 2
        continue
      }
      if bytes[index + 1] == dollar,
        shouldDecodeDollarEscape(bytes: bytes, dollarIndex: index + 1)
      {
        index += 1
        continue
      }
      if index + 3 < bytes.count,
        let first = octalDigit(bytes[index + 1]),
        let second = octalDigit(bytes[index + 2]),
        let third = octalDigit(bytes[index + 3])
      {
        decoded.append(first * 64 + second * 8 + third)
        index += 4
        continue
      }
      if let controlByte = namedControlByte(bytes[index + 1]) {
        decoded.append(controlByte)
        index += 2
        continue
      }

      decoded.append(backslash)
      index += 1
    }

    return String(decoding: decoded, as: UTF8.self)
  }

  private static func shouldDecodeDollarEscape(bytes: [UInt8], dollarIndex: Int) -> Bool {
    guard dollarIndex + 1 < bytes.count else { return false }
    let next = bytes[dollarIndex + 1]
    return next >= 0x80 || next == 0x5F || next == 0x7B
      || (0x41...0x5A).contains(next) || (0x61...0x7A).contains(next)
  }

  private static func octalDigit(_ byte: UInt8) -> UInt8? {
    guard (0x30...0x37).contains(byte) else { return nil }
    return byte - 0x30
  }

  private static func namedControlByte(_ byte: UInt8) -> UInt8? {
    switch byte {
    case 0x61: 0x07
    case 0x62: 0x08
    case 0x76: 0x0B
    case 0x66: 0x0C
    case 0x72: 0x0D
    default: nil
    }
  }
}

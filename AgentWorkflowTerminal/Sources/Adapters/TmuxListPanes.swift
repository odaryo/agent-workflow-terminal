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
  case invalidSessionNameEscape(String)
  case invalidRawFieldEscape(String)
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

public struct TmuxAgentPaneStatus: Sendable, Equatable {
  public let paneID: PaneID
  public let title: String
}

public enum TmuxListPanes {
  private static let formatSeparator = "\u{1F}"
  private static let encodedSeparator: [UInt8] = [0x5C, 0x30, 0x33, 0x37]
  private static let unitSeparator: UInt8 = 0x1F
  private static let backslash: UInt8 = 0x5C
  private static let dollar: UInt8 = 0x24

  /// format に埋めた Unit Separator の見え方は版で異なる。tmux 3.4 の非 control-mode 出力は
  /// これを `\037` にし、3.7c は生 0x1F のまま出す (両版を同一 format で並べて `od -c` 実測)。
  /// 3.7c はリテラル部も値も素通しで、実測した範囲 (ASCII 制御バイト・`$`・0x1F・TAB・LF) では
  /// `\ooo` / named escape (`\a` `\r`) / `\$` を1つも生成しなかった。
  /// slash を持ち得る全フィールドを置換で二重化し、出力段が足す escape だけを奇数列にする。
  /// 置換は版に依らず同一に効く (backslash 連 1/2/3 個で n→2n を両版で実測) ため、3.7c の値の
  /// backslash 列は必ず偶数になる。
  /// session の保存段で `\t` / `\n` / `\ooo` となったテキストも、その `\` バイトを二重化するため
  /// 正式名の一部として偶数列に残る。これにより `$` の後続文字やホストの locale に依存しない。
  /// 保存段そのものは版で違い、3.4 は `$` の前にも `\` を足すが 3.7c は足さない (実測)。
  /// 復号後の session 名が版で変わるのはこのためで、どちらもその版の `has-session -t` が
  /// 求める正式名に一致する。
  /// 制御バイトは 3.4 では 0x01...0x06 / 0x0E...0x1F / 0x7F が八進、BEL / BS / VT / FF / CR が
  /// named escape、TAB / LF が生出力だった。有効な UTF-8 の C1 制御文字は変更されなかった。
  /// 単独 0x80...0x9F と不正 UTF-8 は、実測に使った `pane_current_path` と `pane_title` へは
  /// macOS の path と tmux title が受け付けず投入できなかったため両版とも未確認
  /// (`pane_current_command` を含む他フィールドについても同様に未確認)。
  /// リテラル `\` が `\\` になるのは置換で包んだ5フィールドだけで、通常の区切り走査がそこで順序に
  /// 依存しないのはこのため。残るフィールドは下記のとおり tmux 管理値で backslash を出さない。
  /// 値の中の実 0x1F は区切りと同じ形 (3.4 は `\037`、3.7c は生 0x1F) になり、LF は両版で生のまま
  /// 出るため、その値を含む pane は壊れた値を返さず failure にする。
  /// `pane_dead_status` / `pane_dead_signal` は tmux 管理値で、実測値域が空文字列・非負整数・
  /// signal token のため、ユーザー由来の生フィールドと異なり置換を重ねない。
  ///
  /// - Important: **`pane_title` だけは版をまたいで往復しない (未修正の既知の欠陥)。**
  ///   tmux 3.7c は `#{pane_title}` を展開する時点で backslash を二重化する。実測 (置換を
  ///   挟まない生の `#{pane_title}`、実 title は `t\itle`):
  ///
  ///   | 版 | 生 `#{pane_title}` | 置換後 | `decodeRawField` の結果 |
  ///   | --- | --- | --- | --- |
  ///   | 3.4 | `t\itle` | `t\\itle` | `t\itle` (正しい) |
  ///   | 3.7c | `t\\itle` | `t\\\\itle` | `t\\itle` (backslash が倍) |
  ///
  ///   置換 `s/\\/\\\\/` 自体は**両版とも n→2n** で、上の「置換は版に依らず同一に効く」は
  ///   正しい。ずれるのは `pane_title` の展開段だけで、`session_name` (両版とも展開段で
  ///   二重化される) と `pane_current_path` (両版とも素通し) は往復する。`display-message`
  ///   経由でも同じ挙動 (`TmuxPaneScreenBatch` のマーカー)。title に backslash を出す Agent は
  ///   まだ観測していないため実害は出ていないが、**復号は版依存になっている**。修正は
  ///   影響範囲が広いので別 Issue。
  public static let format = [
    "#{pane_id}",
    #"#{s/\\/\\\\/:session_name}"#,
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

  /// `display-message` の Unit Separator も list-panes と同じ見え方をする (3.4 は `\037`、
  /// 3.7c は生 0x1F。両版で実測) ため、同じ splitter で title 内の backslash と区切りを
  /// 識別する (Gate 3 README §2.1)。
  /// `display-message` は `%H` 等を strftime 展開する点が list-panes と異なるため、
  /// template へ literal `%` を足さない。
  public static let agentPaneStatusFormat = [
    "#{pane_id}",
    #"#{s/\\/\\\\/:pane_title}"#,
  ].joined(separator: formatSeparator)

  public static func parseAgentPaneStatus(
    output: String
  ) throws(TmuxListPanesParseError) -> TmuxAgentPaneStatus {
    var line = output
    if line.hasSuffix("\n") { line.removeLast() }
    let fields = splitEncodedFields(line)
    guard fields.count == 2 else { throw .invalidFieldCount(actual: fields.count) }
    guard fields[0].first == "%", Int(fields[0].dropFirst()) != nil else {
      throw .invalidPaneID(fields[0])
    }
    return TmuxAgentPaneStatus(
      paneID: PaneID(rawValue: fields[0]),
      title: try decodeRawField(fields[1])
    )
  }

  public static func parse(line: String) throws(TmuxListPanesParseError) -> TmuxPane {
    let encodedFields = splitEncodedFields(line)
    guard encodedFields.count == 14 else {
      throw .invalidFieldCount(actual: encodedFields.count)
    }

    guard
      encodedFields[0].first == "%",
      let paneNumber = Int(encodedFields[0].dropFirst()),
      paneNumber >= 0
    else {
      throw .invalidPaneID(encodedFields[0])
    }
    guard let windowIndex = Int(encodedFields[2]), windowIndex >= 0 else {
      throw .invalidWindowIndex(encodedFields[2])
    }
    guard
      encodedFields[3].first == "@",
      let windowNumber = Int(encodedFields[3].dropFirst()),
      windowNumber >= 0
    else {
      throw .invalidWindowID(encodedFields[3])
    }
    guard let paneIndex = Int(encodedFields[4]), paneIndex >= 0 else {
      throw .invalidPaneIndex(encodedFields[4])
    }
    // tmux 3.4 は dead pane にも終了済みプロセスの PID を残すため、live と同じ値域で受け入れる。
    guard let panePID = Int32(encodedFields[5]), panePID > 0 else {
      throw .invalidPanePID(encodedFields[5])
    }

    let isActive = try parsePaneActive(encodedFields[6])
    let isDead = try parsePaneDead(encodedFields[8])
    let termination = try parseTermination(
      isDead: isDead,
      status: encodedFields[9],
      signal: encodedFields[10]
    )

    return TmuxPane(
      paneID: PaneID(rawValue: encodedFields[0]),
      sessionName: try decodeSessionName(encodedFields[1]),
      windowIndex: windowIndex,
      windowID: encodedFields[3],
      paneIndex: paneIndex,
      panePID: panePID,
      isActive: isActive,
      currentCommand: try decodeRawField(encodedFields[7]),
      termination: termination,
      tty: try decodeRawField(encodedFields[11]),
      currentPath: try decodeRawField(encodedFields[12]),
      title: try decodeRawField(encodedFields[13])
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
      // tmux 3.4 は `exit 256` を0、`exit 511` を255として保持したため POSIX 範囲外は拒否する。
      guard let exitStatus = Int32(status), (0...255).contains(exitStatus) else {
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

  /// 区切りは版で形が違う (3.4 = 奇数列の `\` に続く `037`、3.7c = 生 0x1F) が、どちらも
  /// 他方の版の出力には現れないため、版を判定せず両方を受理して曖昧さが出ない。3.7c 側は
  /// 置換により値の `\` 列が必ず偶数になることが根拠で、生 0x1F は区切りか、値に紛れ込んだ
  /// 0x1F (= フィールド数がずれて failure) のどちらかにしかならない。
  private static func splitEncodedFields(_ line: String) -> [String] {
    let bytes = Array(line.utf8)
    var fields: [String] = []
    var fieldStart = 0
    var index = 0

    while index < bytes.count {
      if bytes[index] == unitSeparator {
        fields.append(String(decoding: bytes[fieldStart..<index], as: UTF8.self))
        index += 1
        fieldStart = index
        continue
      }
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

  private static func decodeSessionName(
    _ field: String
  ) throws(TmuxListPanesParseError) -> String {
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
      let slashCount = slashEnd - index
      decoded.append(contentsOf: repeatElement(backslash, count: slashCount / 2))
      guard slashCount.isMultiple(of: 2) else {
        // session_name を置換で包んだ実測では保存済み escape は偶数列になり、
        // 出力段が作る奇数列は `$` の直前にしか現れなかった。
        guard slashEnd < bytes.count, bytes[slashEnd] == dollar else {
          throw .invalidSessionNameEscape(field)
        }
        decoded.append(dollar)
        index = slashEnd + 1
        continue
      }

      index = slashEnd
    }

    return String(decoding: decoded, as: UTF8.self)
  }

  private static func decodeRawField(
    _ field: String
  ) throws(TmuxListPanesParseError) -> String {
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
      let slashCount = slashEnd - index
      decoded.append(contentsOf: repeatElement(backslash, count: slashCount / 2))
      if slashCount.isMultiple(of: 2) {
        index = slashEnd
        continue
      }

      guard slashEnd < bytes.count else {
        throw .invalidRawFieldEscape(field)
      }
      if bytes[slashEnd] == dollar {
        decoded.append(dollar)
        index = slashEnd + 1
        continue
      }
      if let controlByte = namedControlByte(bytes[slashEnd]) {
        decoded.append(controlByte)
        index = slashEnd + 1
        continue
      }
      if let first = octalDigit(bytes[slashEnd]) {
        guard
          slashEnd + 2 < bytes.count,
          let second = octalDigit(bytes[slashEnd + 1]),
          let third = octalDigit(bytes[slashEnd + 2])
        else {
          throw .invalidRawFieldEscape(field)
        }
        let value = Int(first) * 64 + Int(second) * 8 + Int(third)
        // 出力 escape は1バイト由来なので実測上限は `\377`。範囲外は tmux 出力ではない。
        guard let byte = UInt8(exactly: value) else {
          throw .invalidRawFieldEscape(field)
        }
        decoded.append(byte)
        index = slashEnd + 3
        continue
      }

      // ここへ来る `\n` / `\t` を制御バイトへ戻さず pane ごと failure にする。tmux 3.4 の
      // 出力段は TAB / LF を生バイトのまま通し (VIS_TAB / VIS_NL を立てない)、実測で
      // 生成を確認できた escape は `\$` / named (`\a` `\b` `\v` `\f` `\r`) / 八進 `\ooo`
      // だけだった。よってこの2文字列は tmux 出力ではなく、復号すると値を捏造する。
      throw .invalidRawFieldEscape(field)
    }

    return String(decoding: decoded, as: UTF8.self)
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

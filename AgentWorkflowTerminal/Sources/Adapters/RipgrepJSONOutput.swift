import Foundation
import TerminalCore

/// 解釈できなかった stdout の1行。原文を残し、1行の異常で全体を失わない (規約 §2.3)。
public struct RipgrepJSONLineFailure: Sendable, Equatable {
  /// stdout 上の行番号 (1 始まり)。
  public let lineNumber: Int
  public let rawLine: String
}

public struct RipgrepMatchRecord: Sendable, Equatable {
  public let absolutePath: String
  /// ファイル内の行番号 (1 始まり)。
  public let lineNumber: Int
  /// 行の生バイト。行末の改行を含む。`lines.text` の場合も UTF-8 バイト列へ戻して持つ。
  public let lineBytes: [UInt8]
  /// `lineBytes` 先頭からのバイトオフセット。`String.Index` でも文字数でもない。
  public let submatchByteRanges: [Range<Int>]
}

public struct RipgrepJSONOutput: Sendable, Equatable {
  public let matches: [RipgrepMatchRecord]
  /// `--max-count` に達したファイルの絶対パス。
  public let filesReachingPerFileLimit: [String]
  /// `summary` イベントが届いたか。届いていなければ rg は探索を完了していない。
  public let didFinish: Bool
  public let failures: [RipgrepJSONLineFailure]
}

public enum RipgrepJSONOutputParser {
  /// `perFileLimit` は利用者へ見せる1ファイルあたりの上限。rg 15.2.0 の `--json` は
  /// `--max-count` に達したことを一切出力しないため (実測: `matched_lines` は上限値と
  /// 一致するだけで、ちょうどその件数しか無いファイルと区別できず、終了コードも 0)、
  /// 呼び出し側は `perFileLimit + 1` を rg へ渡す。ここで上限 + 1 件目が来たファイルを
  /// 「打ち切った」と確定させ、余分な1件は捨てる。
  public static func parse(
    _ stdout: String,
    perFileLimit: Int = WorktreeSearchLimits.maximumMatchesPerFile
  ) -> RipgrepJSONOutput {
    var accumulator = Accumulator(perFileLimit: perFileLimit)
    let lines = stdout.split(separator: "\n", omittingEmptySubsequences: false)
    for (offset, rawLine) in lines.enumerated() where !rawLine.isEmpty {
      accumulator.consume(String(rawLine), lineNumber: offset + 1)
    }
    return accumulator.finish()
  }
}

private struct Accumulator {
  let perFileLimit: Int

  private var matches: [RipgrepMatchRecord] = []
  private var filesReachingPerFileLimit: [String] = []
  private var failures: [RipgrepJSONLineFailure] = []
  private var didFinish = false
  private var currentPath: String?
  private var currentFileMatchStartIndex = 0
  private let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
  }()

  init(perFileLimit: Int) {
    self.perFileLimit = perFileLimit
  }

  mutating func consume(_ line: String, lineNumber: Int) {
    guard let data = line.data(using: .utf8),
      let kind = try? decoder.decode(EventKind.self, from: data)
    else {
      failures.append(RipgrepJSONLineFailure(lineNumber: lineNumber, rawLine: line))
      return
    }
    // 未知の `type` は無視する。rg が新しいイベントを足しても壊れない。
    guard let type = EventType(rawValue: kind.type) else { return }
    guard let event = try? decoder.decode(Event.self, from: data) else {
      failures.append(RipgrepJSONLineFailure(lineNumber: lineNumber, rawLine: line))
      return
    }

    switch type {
    case .begin:
      closeCurrentFile()
      guard let path = event.data?.path?.decodedText() else {
        failures.append(RipgrepJSONLineFailure(lineNumber: lineNumber, rawLine: line))
        return
      }
      currentPath = path
      currentFileMatchStartIndex = matches.count
    case .match:
      guard let record = Self.record(from: event.data) else {
        failures.append(RipgrepJSONLineFailure(lineNumber: lineNumber, rawLine: line))
        return
      }
      matches.append(record)
    case .end:
      closeCurrentFile()
    case .summary:
      didFinish = true
    }
  }

  mutating func finish() -> RipgrepJSONOutput {
    closeCurrentFile()
    return RipgrepJSONOutput(
      matches: matches, filesReachingPerFileLimit: filesReachingPerFileLimit,
      didFinish: didFinish, failures: failures)
  }

  private mutating func closeCurrentFile() {
    guard let path = currentPath else { return }
    let count = matches.count - currentFileMatchStartIndex
    if count > perFileLimit {
      filesReachingPerFileLimit.append(path)
      matches.removeLast(count - perFileLimit)
    }
    currentPath = nil
  }

  private static func record(from data: Event.EventData?) -> RipgrepMatchRecord? {
    guard let data,
      let path = data.path?.decodedText(),
      let lineBytes = data.lines?.decodedBytes(),
      let number = data.lineNumber, number >= 1
    else { return nil }
    let ranges = (data.submatches ?? []).compactMap { submatch -> Range<Int>? in
      guard submatch.start >= 0, submatch.end >= submatch.start,
        submatch.end <= lineBytes.count
      else { return nil }
      return submatch.start..<submatch.end
    }
    return RipgrepMatchRecord(
      absolutePath: path, lineNumber: number, lineBytes: lineBytes, submatchByteRanges: ranges)
  }
}

private enum EventType: String {
  case begin
  case match
  case end
  case summary
}

private struct EventKind: Decodable {
  let type: String
}

private struct Event: Decodable {
  let data: EventData?

  struct EventData: Decodable {
    let path: TextOrBytes?
    let lines: TextOrBytes?
    let lineNumber: Int?
    let submatches: [Submatch]?
  }

  struct Submatch: Decodable {
    let start: Int
    let end: Int
  }
}

/// rg は UTF-8 なら `{"text": ...}`、そうでなければ `{"bytes": "<base64>"}` を出す。
private struct TextOrBytes: Decodable {
  let text: String?
  let bytes: String?

  func decodedBytes() -> [UInt8]? {
    if let text { return Array(text.utf8) }
    guard let bytes, let data = Data(base64Encoded: bytes) else { return nil }
    return Array(data)
  }

  /// パスは非失敗デコードで受ける (規約 §2.3)。macOS の APFS は非 UTF-8 のファイル名を
  /// 作れない (実測: `EILSEQ`) ので `bytes` 側は実機で現れないが、握り潰すと
  /// 「そのファイルには一致が無かった」と読める結果になるため、置換文字で残す。
  func decodedText() -> String? {
    if let text { return text }
    guard let decoded = decodedBytes() else { return nil }
    return String(decoding: decoded, as: UTF8.self)
  }
}

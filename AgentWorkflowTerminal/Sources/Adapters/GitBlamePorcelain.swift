import Foundation

public struct GitBlamePrevious: Sendable, Equatable {
  public let commitID: String
  public let path: String

  public init(commitID: String, path: String) {
    self.commitID = commitID
    self.path = path
  }
}

/// porcelain は commit ごとのメタデータを、その commit が最初に現れた entry にだけ出す。
/// 見出しが欠けた場合は `nil` のまま持ち、空文字や 0 に丸めない (§12.3)。
public struct GitBlameCommit: Sendable, Equatable {
  public let commitID: String
  public fileprivate(set) var authorName: String?
  public fileprivate(set) var authorMail: String?
  public fileprivate(set) var authoredAt: Date?
  /// `+0900` の形のまま。
  public fileprivate(set) var authorTimeZone: String?
  public fileprivate(set) var summary: String?
  /// `--no-root` を付けているので root commit は必ずここに入る。shallow clone の境界の commit も
  /// 親を持たないので同じ扱いになり、「これより前は辿れない」ことを示す。
  public fileprivate(set) var isBoundary = false
  public fileprivate(set) var previous: GitBlamePrevious?

  /// 未 commit の行は全桁 0 の OID で出る。`author Not Committed Yet` という文言には頼らない。
  public var isUncommitted: Bool { commitID.utf8.allSatisfy { $0 == UInt8(ascii: "0") } }
}

public struct GitBlameLine: Sendable, Equatable {
  public let commitID: String
  public let originalLineNumber: Int
  public let finalLineNumber: Int
  /// その commit 時点のパス。porcelain の `filename` は commit が最初に現れた entry にしか
  /// 出ないので、同じ commit の後続の行はそれを引き継ぐ。
  public let path: String?
  /// 改行を除いた行。CRLF のファイルでは末尾に CR が残る。
  public let content: String
}

public enum GitBlameParseError: Error, Sendable, Equatable {
  case invalidHeader(String)
  case invalidAuthorTime(String)
  case missingContent
}

public struct GitBlameParseFailure: Error, Sendable, Equatable {
  /// 出力の行番号 (1 始まり)。
  public let lineNumber: Int
  public let line: String
  public let error: GitBlameParseError
}

public struct GitBlameParseResult: Sendable, Equatable {
  public let lines: [GitBlameLine]
  public let commits: [String: GitBlameCommit]
  public let failures: [GitBlameParseFailure]

  public func commit(for line: GitBlameLine) -> GitBlameCommit? { commits[line.commitID] }
}

/// `git blame --porcelain` の解析 (設計書 §7.3)。
///
/// 行の分割は UTF-8 のバイト列の LF で行う。`String` の `Character` で分けると、CRLF の
/// ファイルの本文行 (`\tfoo\r\n`) の CR と LF が1つの書記素になり、LF で分けられない。
public enum GitBlamePorcelain {
  fileprivate struct Entry {
    let commitID: String
    let originalLineNumber: Int
    let finalLineNumber: Int
  }

  public static func parse(output: String) -> GitBlameParseResult {
    var rawLines = Array(output.utf8).split(separator: 0x0A, omittingEmptySubsequences: false)
    if rawLines.last?.isEmpty == true { rawLines.removeLast() }
    var parser = Parser()
    for (offset, raw) in rawLines.enumerated() {
      parser.consume(String(decoding: raw, as: UTF8.self), lineNumber: offset + 1)
    }
    return parser.finish()
  }

  private struct Parser {
    private enum State {
      case expectingHeader
      case inEntry(Entry, header: (lineNumber: Int, line: String))
      /// ヘッダが壊れていた entry。次の本文行までを、失敗を重ねずに読み飛ばす。
      case skipping
    }

    private var commits: [String: GitBlameCommit] = [:]
    private var paths: [String: String] = [:]
    private var lines: [GitBlameLine] = []
    private var failures: [GitBlameParseFailure] = []
    private var state = State.expectingHeader

    mutating func consume(_ line: String, lineNumber: Int) {
      switch state {
      case .skipping:
        if line.hasPrefix("\t") { state = .expectingHeader }
      case .expectingHeader:
        startEntry(line, lineNumber: lineNumber)
      case .inEntry(let entry, _):
        continueEntry(entry, line: line, lineNumber: lineNumber)
      }
    }

    func finish() -> GitBlameParseResult {
      var failures = failures
      if case .inEntry(_, let header) = state {
        failures.append(
          .init(lineNumber: header.lineNumber, line: header.line, error: .missingContent))
      }
      return GitBlameParseResult(lines: lines, commits: commits, failures: failures)
    }

    private mutating func startEntry(_ line: String, lineNumber: Int) {
      guard let entry = GitBlamePorcelain.header(line) else {
        failures.append(.init(lineNumber: lineNumber, line: line, error: .invalidHeader(line)))
        state = line.hasPrefix("\t") ? .expectingHeader : .skipping
        return
      }
      if commits[entry.commitID] == nil {
        commits[entry.commitID] = GitBlameCommit(commitID: entry.commitID)
      }
      state = .inEntry(entry, header: (lineNumber, line))
    }

    private mutating func continueEntry(_ entry: Entry, line: String, lineNumber: Int) {
      guard line.hasPrefix("\t") else {
        if let error = apply(line, to: entry.commitID) {
          failures.append(.init(lineNumber: lineNumber, line: line, error: error))
        }
        return
      }
      lines.append(
        GitBlameLine(
          commitID: entry.commitID, originalLineNumber: entry.originalLineNumber,
          finalLineNumber: entry.finalLineNumber, path: paths[entry.commitID],
          content: String(line.dropFirst())))
      state = .expectingHeader
    }

    /// 知らない見出し (`committer` 系、`ignored`、`unblamable` など) は読み飛ばす。
    private mutating func apply(_ line: String, to id: String) -> GitBlameParseError? {
      let key: Substring
      let value: String
      if let space = line.firstIndex(of: " ") {
        key = line[..<space]
        value = String(line[line.index(after: space)...])
      } else {
        key = line[...]
        value = ""
      }
      switch key {
      case "filename":
        paths[id] = GitBlamePorcelain.unquoted(value)
      case "author-time":
        guard let seconds = Int(value) else { return .invalidAuthorTime(value) }
        commits[id]?.authoredAt = Date(timeIntervalSince1970: TimeInterval(seconds))
      case "previous":
        guard let space = value.firstIndex(of: " ") else { return nil }
        commits[id]?.previous = GitBlamePrevious(
          commitID: String(value[..<space]),
          path: GitBlamePorcelain.unquoted(String(value[value.index(after: space)...])))
      default:
        commits[id]?.applyText(key: key, value: value)
      }
      return nil
    }
  }

  fileprivate static func header(_ line: String) -> Entry? {
    let fields = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    guard fields.count == 3 || fields.count == 4, GitObjectID.isValid(fields[0]),
      let original = Int(fields[1]), let final = Int(fields[2]), original > 0, final > 0
    else { return nil }
    if fields.count == 4 {
      guard let count = Int(fields[3]), count > 0 else { return nil }
    }
    return Entry(commitID: fields[0], originalLineNumber: original, finalLineNumber: final)
  }

  /// `core.quotePath=false` でも、`"`・`\`・制御文字を含むパスは C 形式で引用される (実測)。
  fileprivate static func unquoted(_ value: String) -> String {
    value.hasPrefix("\"") ? UnifiedDiffPatch.unquote(value) ?? value : value
  }
}

extension GitBlameCommit {
  fileprivate mutating func applyText(key: Substring, value: String) {
    switch key {
    case "author": authorName = value
    case "author-mail": authorMail = value
    case "author-tz": authorTimeZone = value
    case "summary": summary = value
    case "boundary": isBoundary = true
    default: break
    }
  }
}

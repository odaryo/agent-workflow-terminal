import Foundation

public struct GitFileHistoryChange: Sendable, Equatable {
  public let kind: GitDiffChangeKind
  /// その commit 時点のパス (repository root からの相対)。rename を追うので、現在のパスと
  /// 違うことがある。
  public let path: String
  /// rename / copy の元のパス。
  public let previousPath: String?

  public init(kind: GitDiffChangeKind, path: String, previousPath: String?) {
    self.kind = kind
    self.path = path
    self.previousPath = previousPath
  }
}

public struct GitFileHistoryEntry: Sendable, Equatable, Identifiable {
  public let commitID: String
  public let abbreviatedCommitID: String
  /// `%P` の順序。第1親が先頭。
  public let parentIDs: [String]
  public let authorName: String
  public let authoredAt: Date
  public let summary: String
  /// 空のことがある。`--no-walk` で pathspec に触れない commit を求めると、git 2.55.0 は
  /// name-status の無いヘッダだけを出す (2.50.1 はヘッダも出さない。実測)。
  public let changes: [GitFileHistoryChange]

  public var id: String { commitID }
  public var isMerge: Bool { parentIDs.count > 1 }
}

public enum GitFileHistoryParseError: Error, Sendable, Equatable {
  case truncatedHeader(fieldCount: Int)
  case invalidCommitID(String)
  case invalidAbbreviatedCommitID(String)
  case invalidParentIDs(String)
  case invalidAuthoredAt(String)
  case missingPath(status: String)
}

public struct GitFileHistoryParseFailure: Error, Sendable, Equatable {
  public let recordNumber: Int
  /// NUL 区切りのトークンを `\0` で連結した原文。
  public let record: String
  public let error: GitFileHistoryParseError
}

public enum GitFileHistoryRecord: Sendable, Equatable {
  case entry(GitFileHistoryEntry)
  case failure(GitFileHistoryParseFailure)
}

public struct GitFileHistoryParseResult: Sendable, Equatable {
  /// 出力順。件数の上限判定 (「さらに読む」) は失敗も1件として数える。
  public let records: [GitFileHistoryRecord]

  public var entries: [GitFileHistoryEntry] {
    records.compactMap { if case .entry(let entry) = $0 { entry } else { nil } }
  }

  public var failures: [GitFileHistoryParseFailure] {
    records.compactMap { if case .failure(let failure) = $0 { failure } else { nil } }
  }
}

/// `git log -z --name-status --format=<format>` の解析 (設計書 §7.3)。
///
/// フィールドの区切りに `%x1f` (`GitLog` の方式) を使わないのは、author 名と summary に US が
/// そのまま入るため (実測: `GIT_AUTHOR_NAME` と commit message に入れた US / RS は `%an` /
/// `%s` に残る)。NUL は commit message に入れられない (`git commit` が拒否する) ので、
/// ヘッダを固定個数の NUL 区切りトークンにして位置で読む。
///
/// `-z` の出力は `<ヘッダ 6 トークン>\0\n<status>\0<path>\0[<path>\0]` で、最初の status
/// トークンの先頭に改行が付く (2.50.1 / 2.55.0 で実測)。status は英大文字で始まり、OID は
/// 小文字の16進なので、次のトークンが status か次のヘッダかを取り違えない。
public enum GitFileHistory {
  public static let format = "%H%x00%h%x00%P%x00%an%x00%aI%x00%s"
  private static let headerFieldCount = 6

  public static func parse(output: String) -> GitFileHistoryParseResult {
    var tokens = output.components(separatedBy: "\0")
    if tokens.last?.isEmpty == true { tokens.removeLast() }
    var records: [GitFileHistoryRecord] = []
    var index = 0
    while index < tokens.count {
      let recordNumber = records.count + 1
      let start = index
      guard index + headerFieldCount <= tokens.count else {
        records.append(
          .failure(
            .init(
              recordNumber: recordNumber, record: tokens[index...].joined(separator: "\0"),
              error: .truncatedHeader(fieldCount: tokens.count - index))))
        break
      }
      let header = Array(tokens[index..<index + headerFieldCount])
      index += headerFieldCount
      let changes = parseChanges(tokens, index: &index)
      let record = tokens[start..<index].joined(separator: "\0")
      do {
        records.append(.entry(try entry(header: header, changes: try changes.get())))
      } catch {
        records.append(.failure(.init(recordNumber: recordNumber, record: record, error: error)))
      }
    }
    return .init(records: records)
  }

  private static func parseChanges(
    _ tokens: [String], index: inout Int
  ) -> Result<[GitFileHistoryChange], GitFileHistoryParseError> {
    var changes: [GitFileHistoryChange] = []
    guard index < tokens.count, tokens[index].hasPrefix("\n") else { return .success([]) }
    var status = String(tokens[index].dropFirst())
    while true {
      let isPair = status.first == "R" || status.first == "C"
      let needed = isPair ? 2 : 1
      guard index + needed < tokens.count else {
        index = tokens.count
        return .failure(.missingPath(status: status))
      }
      let first = tokens[index + 1]
      changes.append(
        isPair
          ? .init(kind: kind(of: status), path: tokens[index + 2], previousPath: first)
          : .init(kind: kind(of: status), path: first, previousPath: nil))
      index += needed + 1
      guard index < tokens.count, isStatus(tokens[index]) else { return .success(changes) }
      status = tokens[index]
    }
  }

  private static func entry(
    header: [String], changes: [GitFileHistoryChange]
  ) throws(GitFileHistoryParseError) -> GitFileHistoryEntry {
    guard GitObjectID.isValid(header[0]) else { throw .invalidCommitID(header[0]) }
    guard (4...64).contains(header[1].count), GitObjectID.isHex(header[1]) else {
      throw .invalidAbbreviatedCommitID(header[1])
    }
    let parents = header[2].isEmpty ? [] : header[2].split(separator: " ").map(String.init)
    guard parents.allSatisfy(GitObjectID.isValid) else { throw .invalidParentIDs(header[2]) }
    guard
      let authoredAt = try? Date.ISO8601FormatStyle(includingFractionalSeconds: false)
        .parse(header[4])
    else { throw .invalidAuthoredAt(header[4]) }
    return GitFileHistoryEntry(
      commitID: header[0], abbreviatedCommitID: header[1], parentIDs: parents,
      authorName: header[3], authoredAt: authoredAt, summary: header[5], changes: changes)
  }

  private static func isStatus(_ token: String) -> Bool {
    guard let first = token.unicodeScalars.first, ("A"..."Z").contains(first) else { return false }
    return token.unicodeScalars.dropFirst().allSatisfy { ("0"..."9").contains($0) }
  }

  private static func kind(of status: String) -> GitDiffChangeKind {
    let score = Int(status.dropFirst()) ?? 0
    return switch status.first {
    case "A": .added
    case "C": .copied(score: score)
    case "D": .deleted
    case "M": .modified
    case "R": .renamed(score: score)
    case "T": .typeChanged
    case "U": .unmerged
    default: .unknown(status)
    }
  }
}

enum GitObjectID {
  /// SHA-1 (40 桁) と SHA-256 (64 桁) の repository の両方を受ける。
  static func isValid(_ value: String) -> Bool {
    (value.utf8.count == 40 || value.utf8.count == 64) && isHex(value)
  }

  static func isHex(_ value: String) -> Bool {
    !value.isEmpty
      && value.utf8.allSatisfy {
        ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9"))
          || ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "f"))
      }
  }
}

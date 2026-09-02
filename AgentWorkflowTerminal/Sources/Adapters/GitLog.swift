import Foundation

public struct GitCommit: Sendable, Equatable, Hashable {
  public let hash: String
  public let abbreviatedHash: String
  public let parentHashes: [String]
  public let authorName: String
  public let authorEmail: String
  public let authoredAt: Date
  public let committerName: String
  public let committerEmail: String
  public let committedAt: Date
  public let subject: String
  public let rawBody: String
}

extension GitCommit { public var isMerge: Bool { parentHashes.count > 1 } }

public enum GitLogParseError: Error, Sendable, Equatable {
  case invalidFieldCount(actual: Int)
  case invalidHash(String)
  case invalidAbbreviatedHash(String)
  case invalidParentHashes(String)
  case invalidAuthoredAt(String)
  case invalidCommittedAt(String)
}

public struct GitLogParseFailure: Error, Sendable, Equatable {
  public let recordNumber: Int
  public let record: String
  public let error: GitLogParseError
}

public struct GitLogParseResult: Sendable, Equatable {
  public let commits: [GitCommit]
  public let failures: [GitLogParseFailure]
}

public enum GitLog {
  public static let format = "%H%x1f%h%x1f%P%x1f%an%x1f%ae%x1f%aI%x1f%cn%x1f%ce%x1f%cI%x1f%s%x1f%B"

  public static func parse(output: String) -> GitLogParseResult {
    var records = output.components(separatedBy: "\0")
    if records.last?.isEmpty == true { records.removeLast() }
    var commits: [GitCommit] = []
    var failures: [GitLogParseFailure] = []
    for (index, record) in records.enumerated() where !record.isEmpty {
      do { commits.append(try parse(record: record)) } catch {
        failures.append(.init(recordNumber: index + 1, record: record, error: error))
      }
    }
    return .init(commits: commits, failures: failures)
  }

  private static func parse(record: String) throws(GitLogParseError) -> GitCommit {
    let fields = record.components(separatedBy: "\u{1F}")
    // US は ident/message にも入り得るため、ずれたフィールドを値として返さない。
    guard fields.count == 11 else { throw .invalidFieldCount(actual: fields.count) }
    guard isHex(fields[0], count: 40) else { throw .invalidHash(fields[0]) }
    guard (1...40).contains(fields[1].count), isHex(fields[1], count: fields[1].count) else {
      throw .invalidAbbreviatedHash(fields[1])
    }
    let parents = fields[2].isEmpty ? [] : fields[2].split(separator: " ").map(String.init)
    guard parents.allSatisfy({ isHex($0, count: 40) }) else {
      throw .invalidParentHashes(fields[2])
    }
    let style = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
    guard let authoredAt = try? style.parse(fields[5]) else { throw .invalidAuthoredAt(fields[5]) }
    guard let committedAt = try? style.parse(fields[8]) else {
      throw .invalidCommittedAt(fields[8])
    }
    return GitCommit(
      hash: fields[0], abbreviatedHash: fields[1], parentHashes: parents,
      authorName: fields[3], authorEmail: fields[4], authoredAt: authoredAt,
      committerName: fields[6], committerEmail: fields[7], committedAt: committedAt,
      subject: fields[9], rawBody: fields[10])
  }

  private static func isHex(_ value: String, count: Int) -> Bool {
    value.count == count
      && value.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
  }
}

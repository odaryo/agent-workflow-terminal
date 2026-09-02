import Foundation

public enum GitDiffChangeKind: Sendable, Equatable {
  case added, copied(score: Int), deleted, modified, renamed(score: Int), typeChanged, unmerged,
    unknown(String)
}
public enum GitDiffLineCounts: Sendable, Equatable {
  case text(insertions: Int, deletions: Int)
  case binary
}
public struct GitDiffFileSummary: Sendable, Equatable {
  public let sourceMode: String
  public let destinationMode: String
  public let sourceObject: String
  /// working tree との比較では、未知の object を全桁 0 の OID として git から受け取る。
  public let destinationObject: String
  public let kind: GitDiffChangeKind
  public let path: String
  public let originalPath: String?
  public let lineCounts: GitDiffLineCounts
}
public enum GitDiffParseError: Error, Sendable, Equatable {
  case invalidRawRecord(String)
  case missingRawPath
  case invalidNumstat(String)
  case missingRenamePaths
  case duplicatePath(String)
  case missingNumstat(String)
  case missingRaw(String)
}
public struct GitDiffParseFailure: Error, Sendable, Equatable {
  public let recordNumber: Int
  public let record: String
  public let error: GitDiffParseError
}
public struct GitDiffFileSummariesParseResult: Sendable, Equatable {
  public let summaries: [GitDiffFileSummary]
  public let failures: [GitDiffParseFailure]
}

public enum GitDiffFileSummaries {
  private struct Raw {
    let sourceMode: String
    let destinationMode: String
    let sourceObject: String
    let destinationObject: String
    let kind: GitDiffChangeKind
    let path: String
    let originalPath: String?
    let number: Int
    let record: String
  }
  private struct Stat {
    let path: String
    let counts: GitDiffLineCounts
    let number: Int
    let record: String
  }

  public static func parse(output: String) -> GitDiffFileSummariesParseResult {
    var records = output.components(separatedBy: "\0")
    if records.last?.isEmpty == true { records.removeLast() }
    var raws: [Raw] = []
    var stats: [Stat] = []
    var failures: [GitDiffParseFailure] = []
    var index = 0
    // raw の mode 行に必要な path レコードを先に消費するため、':' path と境界を混同しない。
    while index < records.count, records[index].hasPrefix(":") {
      let number = index + 1
      let record = records[index]
      do {
        let parsed = try parseRaw(record, records: records, index: index)
        raws.append(parsed.raw)
        index += parsed.extra + 1
      } catch {
        failures.append(.init(recordNumber: number, record: record, error: error))
        index += recordsToSkipAfterInvalidRaw(record, records: records, index: index) + 1
      }
    }
    while index < records.count {
      let number = index + 1
      let record = records[index]
      do {
        let parsed = try parseStat(record, records: records, index: index)
        stats.append(parsed.stat)
        index += parsed.extra + 1
      } catch {
        failures.append(.init(recordNumber: number, record: record, error: error))
        index += 1
      }
    }
    var statsByPath = indexStats(stats, failures: &failures)
    var summaries: [GitDiffFileSummary] = []
    for raw in raws {
      guard let stat = statsByPath.removeValue(forKey: raw.path) else {
        failures.append(
          .init(recordNumber: raw.number, record: raw.record, error: .missingNumstat(raw.path)))
        continue
      }
      summaries.append(
        .init(
          sourceMode: raw.sourceMode, destinationMode: raw.destinationMode,
          sourceObject: raw.sourceObject, destinationObject: raw.destinationObject, kind: raw.kind,
          path: raw.path, originalPath: raw.originalPath, lineCounts: stat.counts))
    }
    for stat in stats {
      guard statsByPath[stat.path]?.number == stat.number else { continue }
      failures.append(
        .init(recordNumber: stat.number, record: stat.record, error: .missingRaw(stat.path)))
      statsByPath.removeValue(forKey: stat.path)
    }
    return .init(summaries: summaries, failures: ordered(failures))
  }

  private static func ordered(_ failures: [GitDiffParseFailure]) -> [GitDiffParseFailure] {
    failures.enumerated().sorted {
      if $0.element.recordNumber != $1.element.recordNumber {
        return $0.element.recordNumber < $1.element.recordNumber
      }
      return $0.offset < $1.offset
    }.map(\.element)
  }

  private static func indexStats(
    _ stats: [Stat], failures: inout [GitDiffParseFailure]
  ) -> [String: Stat] {
    var statsByPath: [String: Stat] = [:]
    for stat in stats {
      let previous = statsByPath.updateValue(stat, forKey: stat.path)
      guard previous != nil else { continue }
      failures.append(
        .init(recordNumber: stat.number, record: stat.record, error: .duplicatePath(stat.path)))
    }
    return statsByPath
  }

  // status letter と rename/copy score の直交した分岐を、一つの raw entry として検証する。
  // swiftlint:disable:next cyclomatic_complexity
  private static func parseRaw(
    _ record: String, records: [String], index: Int
  ) throws(GitDiffParseError) -> (raw: Raw, extra: Int) {
    let parts = record.dropFirst().split(separator: " ").map(String.init)
    guard parts.count == 5 else { throw .invalidRawRecord(record) }
    let status = parts[4]
    guard let letter = status.first else { throw .invalidRawRecord(record) }
    let rename = letter == "R" || letter == "C"
    let needed = rename ? 2 : 1
    guard index + needed < records.count else { throw .missingRawPath }
    let old = rename ? records[index + 1] : nil
    let path = records[index + needed]
    let score = Int(status.dropFirst()) ?? 0
    let kind: GitDiffChangeKind =
      switch letter {
      case "A": .added
      case "C": .copied(score: score)
      case "D": .deleted
      case "M": .modified
      case "R": .renamed(score: score)
      case "T": .typeChanged
      case "U": .unmerged
      default: .unknown(String(letter))
      }
    return (
      .init(
        sourceMode: parts[0], destinationMode: parts[1], sourceObject: parts[2],
        destinationObject: parts[3], kind: kind, path: path, originalPath: old, number: index + 1,
        record: record), needed
    )
  }
  private static func parseStat(
    _ record: String, records: [String], index: Int
  ) throws(GitDiffParseError) -> (stat: Stat, extra: Int) {
    let parts = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
    guard parts.count == 3 else { throw .invalidNumstat(record) }
    let counts: GitDiffLineCounts
    if parts[0] == "-", parts[1] == "-" {
      counts = .binary
    } else if let added = Int(parts[0]), let deleted = Int(parts[1]), added >= 0, deleted >= 0 {
      counts = .text(insertions: added, deletions: deleted)
    } else {
      throw .invalidNumstat(record)
    }
    if parts[2].isEmpty {
      guard index + 2 < records.count else { throw .missingRenamePaths }
      return (
        .init(path: records[index + 2], counts: counts, number: index + 1, record: record), 2
      )
    }
    return (.init(path: String(parts[2]), counts: counts, number: index + 1, record: record), 0)
  }

  private static func recordsToSkipAfterInvalidRaw(
    _ record: String, records: [String], index: Int
  ) -> Int {
    let status = record.split(separator: " ").last
    let expectedPaths = status?.first == "R" || status?.first == "C" ? 2 : 1
    return min(expectedPaths, records.count - index - 1)
  }
}

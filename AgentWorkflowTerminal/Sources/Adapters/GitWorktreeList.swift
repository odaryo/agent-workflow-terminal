import Foundation

public struct GitWorktreeEntry: Sendable, Equatable {
  public let path: String
  public let head: String?
  public let branch: String?
  public let isBare: Bool
  public let isDetached: Bool
  public let lockedReason: String?
  public let prunableReason: String?
}

public enum GitWorktreeParseError: Error, Sendable, Equatable { case missingWorktree }
public struct GitWorktreeParseFailure: Error, Sendable, Equatable {
  public let recordNumber: Int
  public let record: String
  public let error: GitWorktreeParseError
}
public struct GitWorktreeListParseResult: Sendable, Equatable {
  public let entries: [GitWorktreeEntry]
  public let failures: [GitWorktreeParseFailure]
}

public enum GitWorktreeList {
  public static func parse(output: String) -> GitWorktreeListParseResult {
    let attributes = output.components(separatedBy: "\0")
    var records: [[String]] = [[]]
    for attribute in attributes {
      if attribute.isEmpty {
        if records.last?.isEmpty == false { records.append([]) }
      } else {
        records[records.count - 1].append(attribute)
      }
    }
    if records.last?.isEmpty == true { records.removeLast() }
    var entries: [GitWorktreeEntry] = []
    var failures: [GitWorktreeParseFailure] = []
    for (index, record) in records.enumerated() {
      if let entry = parse(record) {
        entries.append(entry)
      } else {
        failures.append(
          .init(
            recordNumber: index + 1, record: record.joined(separator: "\0"), error: .missingWorktree
          ))
      }
    }
    return .init(entries: entries, failures: failures)
  }

  private static func parse(_ fields: [String]) -> GitWorktreeEntry? {
    guard let worktree = fields.first(where: { $0.hasPrefix("worktree ") }) else { return nil }
    func value(_ key: String) -> String? {
      fields.first(where: { $0 == key || $0.hasPrefix(key + " ") }).map {
        $0 == key ? "" : String($0.dropFirst(key.count + 1))
      }
    }
    return .init(
      path: String(worktree.dropFirst("worktree ".count)), head: value("HEAD"),
      branch: value("branch"), isBare: fields.contains("bare"),
      isDetached: fields.contains("detached"), lockedReason: value("locked"),
      prunableReason: value("prunable"))
  }
}

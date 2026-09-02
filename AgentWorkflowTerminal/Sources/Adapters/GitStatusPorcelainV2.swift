import Foundation

public struct GitStatusBranch: Sendable, Equatable {
  public let oid: String
  public let head: String
  public let isDetached: Bool
  public let upstream: String?
  public let ahead: Int?
  public let behind: Int?
}
public enum GitFileStatusCode: Character, Sendable, Equatable {
  case unchanged = ".", modified = "M", typeChanged = "T", added = "A", deleted = "D", renamed =
    "R", copied = "C", unmerged = "U"
}
public enum GitSubmoduleState: Sendable, Equatable {
  case notSubmodule
  case submodule(commitChanged: Bool, trackedChanges: Bool, untrackedChanges: Bool)
}
public enum GitRenameOrCopyKind: Sendable, Equatable { case rename, copy }
public struct GitRenameOrCopy: Sendable, Equatable {
  public let kind: GitRenameOrCopyKind; public let score: Int; public let originalPath: String
}
public struct GitStatusChangedEntry: Sendable, Equatable {
  public let indexStatus: GitFileStatusCode; public let worktreeStatus: GitFileStatusCode
  public let submodule: GitSubmoduleState
  /// mode は不在の 000000 と権限を上位層が解釈できるよう git の表現を保つ。
  public let headMode: String; public let indexMode: String; public let worktreeMode: String
  public let headObject: String; public let indexObject: String; public let path: String
  public let renameOrCopy: GitRenameOrCopy?
}
public struct GitStatusUnmergedEntry: Sendable, Equatable {
  public let indexStatus: GitFileStatusCode; public let worktreeStatus: GitFileStatusCode
  public let submodule: GitSubmoduleState
  public let stage1Mode: String; public let stage2Mode: String; public let stage3Mode: String
  public let worktreeMode: String; public let stage1Object: String; public let stage2Object: String
  public let stage3Object: String; public let path: String
}
public enum GitStatusEntry: Sendable, Equatable {
  case changed(GitStatusChangedEntry); case unmerged(GitStatusUnmergedEntry)
  case untracked(path: String); case ignored(path: String)
}
public struct GitStatus: Sendable, Equatable {
  public let branch: GitStatusBranch?; public let entries: [GitStatusEntry]
}
public enum GitStatusParseError: Error, Sendable, Equatable {
  case unknownRecordType(String); case invalidFieldCount(actual: Int); case invalidStatus(String)
  case invalidSubmodule(String); case invalidRename(String); case missingOriginalPath
  case invalidBranchAheadBehind(String)
}
public struct GitStatusParseFailure: Error, Sendable, Equatable {
  public let recordNumber: Int; public let record: String; public let error: GitStatusParseError
}
public struct GitStatusParseResult: Sendable, Equatable {
  public let status: GitStatus; public let failures: [GitStatusParseFailure]
}

public enum GitStatusPorcelainV2 {
  // NUL stream の dispatch を一か所に保ち、rename の追加 record 消費位置をずらさない。
  // swiftlint:disable:next cyclomatic_complexity
  public static func parse(output: String) -> GitStatusParseResult {
    var records = output.components(separatedBy: "\0")
    if records.last?.isEmpty == true { records.removeLast() }
    var oid: String?; var head: String?; var upstream: String?; var ahead: Int?; var behind: Int?
    var entries: [GitStatusEntry] = []; var failures: [GitStatusParseFailure] = []; var index = 0
    while index < records.count {
      let record = records[index]; let number = index + 1
      if record.hasPrefix("# branch.oid ") {
        oid = String(record.dropFirst(13))
      } else if record.hasPrefix("# branch.head ") {
        head = String(record.dropFirst(14))
      } else if record.hasPrefix("# branch.upstream ") {
        upstream = String(record.dropFirst(18))
      } else if record.hasPrefix("# branch.ab ") {
        let values = record.dropFirst(12).split(separator: " ")
        if values.count == 2, let aheadCount = Int(values[0].dropFirst()),
          let behindCount = Int(values[1].dropFirst())
        {
          ahead = aheadCount
          behind = behindCount
        } else {
          failures.append(
            .init(recordNumber: number, record: record, error: .invalidBranchAheadBehind(record)))
        }
      } else if record.hasPrefix("# ") {
        // 将来追加される header のため、既知 record の部分成功を失わせない。
      } else {
        do {
          let parsed = try parseEntry(
            record, originalPath: index + 1 < records.count ? records[index + 1] : nil)
          entries.append(parsed.entry); if parsed.consumedOriginal { index += 1 }
        } catch { failures.append(.init(recordNumber: number, record: record, error: error)) }
      }
      index += 1
    }
    let branch: GitStatusBranch?
    if let oid, let head {
      branch = GitStatusBranch(
        oid: oid, head: head, isDetached: head == "(detached)", upstream: upstream,
        ahead: ahead, behind: behind)
    } else {
      branch = nil
    }
    return .init(status: .init(branch: branch, entries: entries), failures: failures)
  }

  private static func parseEntry(
    _ record: String, originalPath: String?
  ) throws(GitStatusParseError) -> (entry: GitStatusEntry, consumedOriginal: Bool) {
    if record.hasPrefix("? ") { return (.untracked(path: String(record.dropFirst(2))), false) }
    if record.hasPrefix("! ") { return (.ignored(path: String(record.dropFirst(2))), false) }
    let type = record.first
    guard type == "1" || type == "2" || type == "u" else {
      throw .unknownRecordType(String(type.map { String($0) } ?? ""))
    }
    let expected = type == "u" ? 11 : (type == "2" ? 10 : 9)
    let parts = record.split(
      separator: " ", maxSplits: expected - 1, omittingEmptySubsequences: true
    ).map(String.init)
    guard parts.count == expected else { throw .invalidFieldCount(actual: parts.count) }
    let statuses = try parseStatuses(parts[1]); let submodule = try parseSubmodule(parts[2])
    if type == "u" {
      return (
        .unmerged(
          .init(
            indexStatus: statuses.0, worktreeStatus: statuses.1, submodule: submodule,
            stage1Mode: parts[3], stage2Mode: parts[4], stage3Mode: parts[5],
            worktreeMode: parts[6], stage1Object: parts[7], stage2Object: parts[8],
            stage3Object: parts[9], path: parts[10])), false
      )
    }
    var rename: GitRenameOrCopy?
    if type == "2" {
      guard let originalPath else { throw .missingOriginalPath }
      let token = parts[8]
      guard let kindCharacter = token.first, let score = Int(token.dropFirst()),
        kindCharacter == "R" || kindCharacter == "C"
      else { throw .invalidRename(token) }
      rename = .init(
        kind: kindCharacter == "R" ? .rename : .copy, score: score, originalPath: originalPath)
    }
    let pathIndex = type == "2" ? 9 : 8
    return (
      .changed(
        .init(
          indexStatus: statuses.0, worktreeStatus: statuses.1, submodule: submodule,
          headMode: parts[3], indexMode: parts[4], worktreeMode: parts[5], headObject: parts[6],
          indexObject: parts[7], path: parts[pathIndex], renameOrCopy: rename)), type == "2"
    )
  }
  private static func parseStatuses(
    _ value: String
  ) throws(GitStatusParseError) -> (GitFileStatusCode, GitFileStatusCode) {
    let values = Array(value)
    guard values.count == 2, let first = GitFileStatusCode(rawValue: values[0]),
      let second = GitFileStatusCode(rawValue: values[1])
    else { throw .invalidStatus(value) }; return (first, second)
  }
  private static func parseSubmodule(
    _ value: String
  ) throws(GitStatusParseError) -> GitSubmoduleState {
    if value == "N..." { return .notSubmodule }; let values = Array(value)
    guard values.count == 4, values[0] == "S", [".", "C"].contains(values[1]),
      [".", "M"].contains(values[2]), [".", "U"].contains(values[3])
    else { throw .invalidSubmodule(value) }
    return .submodule(
      commitChanged: values[1] == "C", trackedChanges: values[2] == "M",
      untrackedChanges: values[3] == "U")
  }
}

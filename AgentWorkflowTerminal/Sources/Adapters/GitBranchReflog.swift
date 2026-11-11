import Foundation

/// `git reflog show --format=%gs refs/heads/<branch> --` の出力を読む (§9.1.1)。出力は新しい順で、
/// 最終行が最古 (git 2.54.0 で計測。`--reverse` は `--walk-reflogs` と併用できず rc=128)。
enum GitBranchReflog {
  private static let resetToPrefix = "branch: Reset to "
  private static let createdFromPrefix = "branch: Created from "

  static func resetToStartPoints(subjects output: String) -> [String] {
    var seen: Set<String> = []
    return output.split(separator: "\n").compactMap { line in
      guard line.hasPrefix(resetToPrefix) else { return nil }
      let startPoint = String(line.dropFirst(resetToPrefix.count))
      guard !startPoint.isEmpty, seen.insert(startPoint).inserted else { return nil }
      return startPoint
    }
  }

  /// 最終行より上へ遡らない。reflog の一部が失効すると最古の項目は作成の項目でなくなり、そのとき
  /// 分岐元は分からない。rename / copy の項目 (`Branch: renamed ...`) は上に積まれるので、最終行は
  /// 作成の項目のまま残る。
  static func createdFromStartPoint(subjects output: String) -> String? {
    let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
    guard let last = lines.last(where: { !$0.isEmpty }),
      last.hasPrefix(createdFromPrefix)
    else { return nil }
    let startPoint = last.dropFirst(createdFromPrefix.count)
    return startPoint.isEmpty ? nil : String(startPoint)
  }
}

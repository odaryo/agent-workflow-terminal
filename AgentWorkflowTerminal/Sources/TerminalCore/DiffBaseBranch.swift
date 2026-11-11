import Foundation

public enum DiffBaseBranchSource: Sendable, Equatable, Hashable {
  case userSelection
  case forkPoint
  case originHead
}

public enum DiffBaseBranch: Sendable, Equatable {
  case resolved(branch: GitBranchRef, source: DiffBaseBranchSource)
  /// 分岐元も `origin/HEAD` も解決できなかった状態。ユーザーが選ぶまで Diff は出せない。
  /// 判定不能を `main` へ丸めない (§9.1.1)。
  case undetermined

  public var branch: GitBranchRef? {
    switch self {
    case .resolved(let branch, _): branch
    case .undetermined: nil
    }
  }
}

public enum DiffBaseBranchResolver {
  /// 空白だけの値は「解決できなかった」として扱う。`git` の出力が空行になる場合と、
  /// UI の未入力を同じ「無い」へ寄せるため。
  public static func resolve(
    userSelection: GitBranchRef?,
    forkPoint: GitBranchRef?,
    originHead: GitBranchRef?
  ) -> DiffBaseBranch {
    if let name = normalized(userSelection) {
      return .resolved(branch: name, source: .userSelection)
    }
    if let name = normalized(forkPoint) { return .resolved(branch: name, source: .forkPoint) }
    if let name = normalized(originHead) { return .resolved(branch: name, source: .originHead) }
    return .undetermined
  }

  private static func normalized(_ value: GitBranchRef?) -> GitBranchRef? {
    guard let value else { return nil }
    let trimmed = value.shortName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    switch value {
    case .local: return .local(trimmed)
    case .remote: return .remote(trimmed)
    }
  }
}

/// §9.1.1 の分岐元の採否。git は `branch: Created from <ref>` の `<ref>` を入力どおりに記録し、
/// `rev-parse --symbolic-full-name` は記録時ではなく今の文脈で解決する (git 2.54.0 で計測)。
/// `HEAD` / `@` は今の branch 自身に、`@{-1}` は今の直前の branch に解決されるので、記録した名前と
/// 解決した完全名が一致するときだけ採る。`origin/HEAD` も一致しないが、`origin/HEAD` の段で同じ
/// branch に着く。
public enum DiffForkPoint {
  /// `resolvedFullName` は `<ref>` の `rev-parse --verify --quiet --symbolic-full-name` の stdout
  /// (trim 済み)。OID・`main~0`・曖昧な名前では空になる。
  public static func branch(
    recordedStartPoint: String,
    resolvedFullName: String,
    currentBranch: GitBranchRef
  ) -> GitBranchRef? {
    let candidates = [
      recordedStartPoint, "refs/heads/" + recordedStartPoint, "refs/remotes/" + recordedStartPoint,
    ]
    guard candidates.contains(resolvedFullName),
      let branch = GitBranchRef(fullName: resolvedFullName), branch != currentBranch
    else { return nil }
    return branch
  }
}

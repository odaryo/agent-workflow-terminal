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
  ///
  /// `resolvedFullName` と候補は `String ==` (正準等価) で比べる。`Process` は argv を NFD へ分解して
  /// 渡し、`rev-parse` はそれを NFC へ戻さないので、既定の設定 (`core.precomposeunicode=true`) でも
  /// NFC の記録から NFD の完全名が返る (git 2.54.0 で計測、Issue #842)。
  ///
  /// 採る名前は、`listedBranches` (`for-each-ref refs/heads/ refs/remotes/` の一覧) にバイト列で在る
  /// 候補の綴りにし、`resolvedFullName` の綴りは採らない。大文字小文字や正規化を区別しない volume では、
  /// `rev-parse` は一覧に無い綴り (`Main` や、`core.precomposeunicode=false` での NFD) でも loose ref を
  /// 開けて解決し、その名前は `pack-refs` の後には解決できなくなる。`String ==` は NFC と NFD を同じと
  /// みなすので、一覧との照合はバイト列で行う。近い綴りの ref には寄せない。
  ///
  /// 同名の remote-tracking ref は比較元が自分自身になるため採らない (§9.1.1、Issue #838)。
  /// この除外は自分自身の除外と同じ `String ==` (正準等価) でよい。広く弾いても `origin/HEAD` へ
  /// 進むだけで、比較元とその経路は Diff 上部に出てユーザーが選び直せるため (§9.1.4)、
  /// 一覧との照合のようなバイト列の一致は求めない。
  public static func branch(
    recordedStartPoint: String,
    resolvedFullName: String,
    currentBranch: GitBranchRef,
    listedBranches: [GitBranchRef],
    remoteNames: [String]
  ) -> GitBranchRef? {
    let candidates = [
      recordedStartPoint, "refs/heads/" + recordedStartPoint, "refs/remotes/" + recordedStartPoint,
    ]
    guard
      let listed = candidates.first(where: { candidate in
        candidate == resolvedFullName
          && listedBranches.contains { $0.fullName.utf8.elementsEqual(candidate.utf8) }
      }),
      let branch = GitBranchRef(fullName: listed), branch != currentBranch
    else { return nil }
    if case .remote(let name) = branch,
      remoteNames.contains(where: { name == $0 + "/" + currentBranch.shortName })
    {
      return nil
    }
    return branch
  }
}

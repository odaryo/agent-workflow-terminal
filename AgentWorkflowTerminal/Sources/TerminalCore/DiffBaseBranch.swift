import Foundation

public enum DiffBaseBranchSource: Sendable, Equatable, Hashable {
  case userSelection
  case upstream
  case originHead
}

public enum DiffBaseBranch: Sendable, Equatable {
  case resolved(branch: String, source: DiffBaseBranchSource)
  /// upstream も `origin/HEAD` も解決できなかった状態。ユーザーが選ぶまで Diff は出せない。
  /// 判定不能を `main` へ丸めない (§9.1.1)。
  case undetermined

  public var branch: String? {
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
    userSelection: String?,
    upstream: String?,
    originHead: String?
  ) -> DiffBaseBranch {
    if let name = normalized(userSelection) {
      return .resolved(branch: name, source: .userSelection)
    }
    if let name = normalized(upstream) { return .resolved(branch: name, source: .upstream) }
    if let name = normalized(originHead) { return .resolved(branch: name, source: .originHead) }
    return .undetermined
  }

  private static func normalized(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

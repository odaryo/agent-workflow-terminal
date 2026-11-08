import TerminalCore

public struct GitRefNames: Sendable, Equatable {
  public let localBranches: [GitBranchRef]
  public let remoteBranches: [GitBranchRef]

  public var all: [GitBranchRef] { localBranches + remoteBranches }
}

public enum GitRefNameList {
  /// `git for-each-ref --format=%(refname) refs/heads/ refs/remotes/` の出力。refname は改行も
  /// NUL も含み得ないため (`git check-ref-format`)、行区切りで安全に読める。
  public static func parse(output: String) -> GitRefNames {
    var local: [GitBranchRef] = []
    var remote: [GitBranchRef] = []
    for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
      guard let branch = GitBranchRef(fullName: String(line)) else { continue }
      switch branch {
      case .local: local.append(branch)
      case .remote: remote.append(branch)
      }
    }
    return GitRefNames(localBranches: local, remoteBranches: remote)
  }
}

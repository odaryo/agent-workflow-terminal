import Foundation

public struct GitRefNames: Sendable, Equatable {
  public let localBranches: [String]
  /// `origin/main` のような remote-tracking branch の短縮名。
  public let remoteBranches: [String]

  public var all: [String] { localBranches + remoteBranches }
}

public enum GitRefNameList {
  /// `git for-each-ref --format=%(refname) refs/heads/ refs/remotes/` の出力。refname は改行も
  /// NUL も含み得ないため (`git check-ref-format`)、行区切りで安全に読める。
  public static func parse(output: String) -> GitRefNames {
    var local: [String] = []
    var remote: [String] = []
    for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
      let name = String(line)
      if let short = name.dropPrefix("refs/heads/") {
        local.append(short)
      } else if let short = name.dropPrefix("refs/remotes/") {
        // `refs/remotes/<remote>/HEAD` は branch ではなく symbolic ref なので候補に出さない。
        guard !short.hasSuffix("/HEAD") else { continue }
        remote.append(short)
      }
    }
    return GitRefNames(localBranches: local, remoteBranches: remote)
  }

  /// `git symbolic-ref refs/remotes/origin/HEAD` の出力 (`refs/remotes/origin/main`) を
  /// `git merge-base` へ渡せる短縮名にする。
  public static func shortenRemoteRef(_ output: String) -> String? {
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let short = trimmed.dropPrefix("refs/remotes/"), !short.isEmpty else { return nil }
    return short
  }
}

extension String {
  fileprivate func dropPrefix(_ prefix: String) -> String? {
    hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
  }
}

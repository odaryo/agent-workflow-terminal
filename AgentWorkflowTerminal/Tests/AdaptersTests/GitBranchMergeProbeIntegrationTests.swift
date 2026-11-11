import Foundation
import TerminalCore
import Testing

@testable import Adapters

/// 実 git に対して、Overview のマージ済みの印 (Issue #879) の判定が Close と同じ §3.4 の判定
/// (ancestor + squash merge) を返すことを固定する。fixture で固定できない理由は
/// `GitSquashMergeCloseIntegrationTests` と同じ。
///
/// `.serialized` も同じ理由 (負荷)。
@Suite("Issue #879 実 git のマージ済みの判定を印の probe が拾う", .serialized)
struct GitBranchMergeProbeIntegrationTests {
  @Test("--no-ff で取り込んだ branch は ancestor の根拠で merged")
  func detectsNoFastForwardMerge() async throws {
    try await withGitRepository { repository in
      try await repository.addProbeBranchWorktree("topic", commits: [["a.txt": "a1"]])
      try await repository.git(["merge", "-q", "--no-ff", "-m", "merge topic", "topic"])

      let tip = try await repository.branchTip("topic")
      #expect(try await repository.probedMergeStatus("topic") == .merged(.ancestor, tip: tip))
    }
  }

  @Test("squash merge した branch は squash の根拠で merged")
  func detectsSquashMerge() async throws {
    try await withGitRepository { repository in
      try await repository.addProbeBranchWorktree(
        "topic", commits: [["a.txt": "a1"], ["b.txt": "b1"]])
      // `merge --squash` は HEAD を進めないので、GitHub の squash merge と同じく commit を作る。
      try await repository.git(["merge", "-q", "--squash", "topic"])
      try await repository.git(["commit", "-q", "-m", "squash topic"])

      let tip = try await repository.branchTip("topic")
      #expect(try await repository.probedMergeStatus("topic") == .merged(.squash, tip: tip))
    }
  }

  @Test("未マージの branch は unmerged")
  func keepsUnmergedBranchUnmerged() async throws {
    try await withGitRepository { repository in
      try await repository.addProbeBranchWorktree("topic", commits: [["a.txt": "a1"]])
      try await repository.addProbeBranchWorktree("other", commits: [["b.txt": "b1"]])
      try await repository.git(["merge", "-q", "--no-ff", "-m", "merge other", "other"])

      #expect(try await repository.probedMergeStatus("topic") == .unmerged)
    }
  }
}

extension GitTestRepository {
  /// `commits` の 1 要素が 1 commit で、値はそのパスへ書く内容。
  fileprivate func addProbeBranchWorktree(
    _ branch: String, commits: [[String: String]]
  ) async throws {
    try await git(["worktree", "add", "-q", "-b", branch, "../\(branch)"])
    for files in commits {
      for (name, contents) in files {
        try (contents + "\n").write(
          to: root.appending(path: "\(branch)/\(name)"), atomically: true, encoding: .utf8)
      }
      try await git(["add", "-A"], in: branch)
      try await git(["commit", "-q", "-m", "commit on \(branch)"], in: branch)
    }
  }

  /// 先端は製品とは別の経路 (`branchTip`: `log --format=%H`) で読んだ値と突き合わせる。
  fileprivate func probedMergeStatus(_ branch: String) async throws -> BranchMergeStatus {
    let probe = GitBranchMergeProbe(
      runner: try runner(globalConfig: ""), mergeCache: GitBranchMergeCache())
    let tip = try #require(await probe.branchTip(branch))
    #expect(tip == (try await branchTip(branch)))
    let destination = try #require(await probe.defaultBranchTip(projectRootBranch: "main"))
    #expect(destination == (try await branchTip("main")))
    return await probe.mergeStatus(tip: tip, destination: destination)
  }
}

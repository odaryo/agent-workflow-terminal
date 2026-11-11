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

  /// nil の答えでも印は出ないので、印の有無だけでは親の無い行を誤って判定不能にした退行を
  /// 見逃す。`isOnFirstParentChain` の生の答えも比べる (#912)。
  @Test(
    "first-parent の列の上にある先端を拾い、--no-ff・octopus・無関係な履歴の merge・squash に印を出す",
    arguments: FirstParentScenario.allCases)
  func judgesFirstParentChainPerScenario(scenario: FirstParentScenario) async throws {
    try await withGitRepository { repository in
      try await scenario.arrange(in: repository)

      let tip = try await repository.branchTip("topic")
      let (status, onFirstParentChain) = try await repository.probedMarkInputs("topic")

      #expect(status == .merged(scenario.expectedEvidence, tip: tip))
      #expect(onFirstParentChain == scenario.expectedOnFirstParentChain)
      let marked =
        switch status {
        case .merged(.squash, _): true
        case .merged(.ancestor, _): onFirstParentChain == false
        default: false
        }
      #expect(marked == scenario.expectedMark)
    }
  }
}

/// branch は `topic`。`Advanced` の付く場合は、最後に既定 branch を1つ進め、先端と既定 branch の
/// 先端が同じという近道を通らずに rev-list の経路を通す。
/// `noffAdvanced` と `octopus` は複数行、`unrelated` と `skewedNoff` は親の無い最終行を
/// 扱う。日時のずれは7 commit で root まで行き過ぎ、6以下では行き過ぎなかったため、
/// 余裕を取って10 commit にする (git 2.54.0 で計測、#912)。
enum FirstParentScenario: String, CaseIterable, CustomTestStringConvertible, Sendable {
  case fresh
  case freshAdvanced
  case ffsync
  case noff
  case noffAdvanced
  case octopus
  case unrelated
  case skewedNoff
  case skewedFfmergeAdvanced
  case ffmerge
  case ffmergeAdvanced
  case squash
  case nolog

  var testDescription: String { rawValue }

  var expectedEvidence: BranchMergeEvidence {
    self == .squash ? .squash : .ancestor
  }

  var expectedOnFirstParentChain: Bool {
    switch self {
    case .noff, .noffAdvanced, .octopus, .unrelated, .skewedNoff, .squash: false
    case .fresh, .freshAdvanced, .ffsync, .ffmerge, .ffmergeAdvanced, .skewedFfmergeAdvanced,
      .nolog:
      true
    }
  }

  var expectedMark: Bool { !expectedOnFirstParentChain }

  func arrange(in repository: GitTestRepository) async throws {
    switch self {
    case .fresh:
      try await repository.git(["branch", "topic"])
    case .freshAdvanced:
      try await repository.git(["branch", "topic"])
      try await repository.commit(file: "m1.txt", contents: "m1", in: nil)
    case .ffsync:
      try await repository.addProbeBranchWorktree("topic", commits: [])
      try await repository.commit(file: "m1.txt", contents: "m1", in: nil)
      try await repository.git(["merge", "-q", "--ff-only", "main"], in: "topic")
      try await repository.commit(file: "m2.txt", contents: "m2", in: nil)
    case .noff, .noffAdvanced:
      try await repository.addProbeBranchWorktree("topic", commits: [["a.txt": "a1"]])
      try await repository.git(["merge", "-q", "--no-ff", "-m", "merge topic", "topic"])
      if self == .noffAdvanced {
        try await repository.commit(file: "m1.txt", contents: "m1", in: nil)
      }
    case .octopus, .unrelated, .skewedNoff, .skewedFfmergeAdvanced:
      try await arrangeSideHistoryMerge(in: repository)
    case .ffmerge, .ffmergeAdvanced:
      try await repository.addProbeBranchWorktree("topic", commits: [["a.txt": "a1"]])
      try await repository.git(["merge", "-q", "--ff-only", "topic"])
      if self == .ffmergeAdvanced {
        try await repository.commit(file: "m1.txt", contents: "m1", in: nil)
      }
    case .squash:
      try await repository.addProbeBranchWorktree(
        "topic", commits: [["a.txt": "a1"], ["b.txt": "b1"]])
      try await repository.git(["merge", "-q", "--squash", "topic"])
      try await repository.git(["commit", "-q", "-m", "squash topic"])
    case .nolog:
      try await repository.commit(file: "m1.txt", contents: "m1", in: nil)
      try await repository.git(
        ["-c", "core.logAllRefUpdates=false", "branch", "topic", "main~1"])
    }
  }

  private func arrangeSideHistoryMerge(in repository: GitTestRepository) async throws {
    if self == .octopus {
      try await repository.addProbeBranchWorktree("topic", commits: [["a.txt": "a1"]])
      try await repository.addProbeBranchWorktree("other", commits: [["b.txt": "b1"]])
      try await repository.git(["merge", "-q", "--no-ff", "-m", "oct", "topic", "other"])
      return
    }
    if self == .unrelated {
      try await repository.commit(file: "m1.txt", contents: "m1", in: nil)
      let result = try await repository.gitExitCode(
        ["commit-tree", "HEAD^{tree}", "-m", "unrelated"])
      try #require(result.exitCode == 0)
      let tip = result.stdout.trimmingCharacters(in: .newlines)
      try await repository.git(["branch", "topic", tip])
      try await repository.git(
        ["merge", "-q", "--allow-unrelated-histories", "--no-ff", "-m", "merge", "topic"])
      return
    }
    if self == .skewedNoff {
      try await repository.commit(file: "m1.txt", contents: "m1", in: nil)
    }
    try await repository.addProbeBranchWorktree(
      "topic", commits: (1...10).map { ["a.txt": "a\($0)"] },
      commitDate: "2001-01-01T00:00:00Z")
    if self == .skewedNoff {
      try await repository.git(["merge", "-q", "--no-ff", "-m", "merge topic", "topic"])
    } else {
      try await repository.git(["merge", "-q", "--ff-only", "topic"])
      try await repository.commit(file: "m1.txt", contents: "m1", in: nil)
    }
  }
}

extension GitTestRepository {
  /// `commits` の 1 要素が 1 commit で、値はそのパスへ書く内容。
  fileprivate func addProbeBranchWorktree(
    _ branch: String, commits: [[String: String]], commitDate: String? = nil
  ) async throws {
    try await git(["worktree", "add", "-q", "-b", branch, "../\(branch)"])
    for files in commits {
      for (name, contents) in files {
        try (contents + "\n").write(
          to: root.appending(path: "\(branch)/\(name)"), atomically: true, encoding: .utf8)
      }
      try await git(["add", "-A"], in: branch)
      try await git(
        ["commit", "-q", "-m", "commit on \(branch)"], in: branch,
        additionalEnvironment: commitDate.map {
          ["GIT_COMMITTER_DATE": $0, "GIT_AUTHOR_DATE": $0]
        } ?? [:])
    }
  }

  /// 先端は製品とは別の経路 (`branchTip`: `log --format=%H`) で読んだ値と突き合わせる。
  fileprivate func probedMergeStatus(_ branch: String) async throws -> BranchMergeStatus {
    let probe = GitBranchMergeProbe(
      runner: try runner(globalConfig: "", ignoresHistoryRewrites: true),
      mergeCache: GitBranchMergeCache())
    let tip = try #require(await probe.branchTip(branch))
    #expect(tip == (try await branchTip(branch)))
    let destination = try #require(await probe.defaultBranchTip(projectRootBranch: "main"))
    #expect(destination == (try await branchTip("main")))
    return await probe.mergeStatus(tip: tip, destination: destination)
  }

  fileprivate func probedMarkInputs(
    _ branch: String
  ) async throws -> (status: BranchMergeStatus, onFirstParentChain: Bool?) {
    let probe = GitBranchMergeProbe(
      runner: try runner(globalConfig: "", ignoresHistoryRewrites: true),
      mergeCache: GitBranchMergeCache())
    let tip = try #require(await probe.branchTip(branch))
    let destination = try #require(await probe.defaultBranchTip(projectRootBranch: "main"))
    #expect(destination == (try await branchTip("main")))
    return (
      await probe.mergeStatus(tip: tip, destination: destination),
      await probe.isOnFirstParentChain(tip: tip, destination: destination)
    )
  }
}

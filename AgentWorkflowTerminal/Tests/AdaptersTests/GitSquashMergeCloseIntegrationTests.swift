import Foundation
import TerminalCore
import Testing

@testable import Adapters

/// 実 git に対して §3.4 の「マージ済みの判定は ancestor 判定だけでなく patch 相当の同一性
/// (squash merge) も検出する」(確定 2026-09-08) を固定する。
///
/// fixture では固定できない。判定は `merge-base` / `log` / `diff --raw` の**実 git の出力の
/// 組み合わせ**であり、squash merge が既定 branch 側でどの blob 遷移になるかは実際に
/// `merge --squash` を通さないと再現できない。
@Suite("§3.4 実 git の squash merge を Close の merge 判定が拾う")
struct GitSquashMergeCloseIntegrationTests {
  @Test("fast-forward で取り込んだ branch は ancestor 判定のまま merged")
  func detectsAncestorMerge() async throws {
    try await withGitRepository { repository in
      try await repository.addBranchWorktree("topic", commits: [["a.txt": "a1"]])
      try await repository.git(["merge", "-q", "--ff-only", "topic"])

      #expect(try await repository.branchMergeStatus("topic") == .merged)
    }
  }

  @Test("1 commit の branch を squash merge した後は merged")
  func detectsSingleCommitSquashMerge() async throws {
    try await withGitRepository { repository in
      try await repository.addBranchWorktree("topic", commits: [["a.txt": "a1"]])
      try await repository.squashMerge("topic")

      #expect(try await repository.branchMergeStatus("topic") == .merged)
    }
  }

  @Test("3 commit の branch を squash merge した後は merged")
  func detectsMultipleCommitSquashMerge() async throws {
    try await withGitRepository { repository in
      // 個々の commit の patch はどれも squash commit と一致しない。`git cherry` が
      // この形を検出できない (実測: 全行が `+`) ため、合成差分で突き合わせている。
      try await repository.addBranchWorktree(
        "topic", commits: [["a.txt": "a1"], ["a.txt": "a1\na2"], ["b.txt": "b1"]])
      try await repository.squashMerge("topic")

      #expect(try await repository.branchMergeStatus("topic") == .merged)
    }
  }

  @Test("squash merge の前に既定 branch が別ファイルを変えていても merged")
  func detectsSquashMergeAfterDefaultBranchMoved() async throws {
    try await withGitRepository { repository in
      try await repository.addBranchWorktree(
        "topic", commits: [["a.txt": "a1"], ["b.txt": "b1"]])
      try await repository.commitOnDefaultBranch(files: ["unrelated.txt": "u1"])
      try await repository.squashMerge("topic")

      #expect(try await repository.branchMergeStatus("topic") == .merged)
    }
  }

  @Test("未マージの branch は unmerged のままで、merged へ丸めない")
  func keepsUnmergedBranchUnmerged() async throws {
    try await withGitRepository { repository in
      try await repository.addBranchWorktree(
        "topic", commits: [["a.txt": "a1"], ["b.txt": "b1"]])
      try await repository.commitOnDefaultBranch(files: ["unrelated.txt": "u1"])

      #expect(try await repository.branchMergeStatus("topic") == .unmerged)
    }
  }

  @Test("squash merge の後に積んだ commit がある branch は unmerged")
  func keepsPartiallyMergedBranchUnmerged() async throws {
    try await withGitRepository { repository in
      try await repository.addBranchWorktree("topic", commits: [["a.txt": "a1"]])
      try await repository.squashMerge("topic")
      try await repository.commitOnBranchWorktree("topic", files: ["a.txt": "a1\na2"])

      #expect(try await repository.branchMergeStatus("topic") == .unmerged)
    }
  }

  @Test("差分が相殺された branch を、既定 branch の空 commit と一致させない")
  func doesNotMatchEmptyChangeAgainstEmptyCommit() async throws {
    try await withGitRepository { repository in
      // 追加して削除した branch の合成差分は空になる。既定 branch 側の空 commit の差分も
      // 空なので、内容差の空を除外しないと未マージの 2 commit が merged に化ける (実測)。
      try await repository.addBranchWorktree("topic", commits: [["tmp.txt": "t1"]])
      try await repository.removeOnBranchWorktree("topic", file: "tmp.txt")
      try await repository.git(["commit", "-q", "--allow-empty", "-m", "empty"])

      #expect(try await repository.branchMergeStatus("topic") == .unmerged)
    }
  }

  @Test("上限は新しい方から数える。上限内の squash は拾い、外は unmerged へ倒す")
  func scansNewestCommitsWithinScanLimit() async throws {
    try await withGitRepository { repository in
      try await repository.addBranchWorktree("topic", commits: [["a.txt": "a1"]])
      try await repository.commitOnDefaultBranch(files: ["unrelated.txt": "u1"])
      try await repository.squashMerge("topic")

      // 既定 branch 側は [squash(新), unrelated(古)]。上限 1 でも最新の squash は見る。
      #expect(try await repository.branchMergeStatus("topic", scanLimit: 1) == .merged)
    }
  }

  @Test("上限より古い位置にある squash は走査せず unmerged にする")
  func stopsAtScanLimitWithoutReachingOlderSquash() async throws {
    try await withGitRepository { repository in
      try await repository.addBranchWorktree("topic", commits: [["a.txt": "a1"]])
      try await repository.squashMerge("topic")
      try await repository.commitOnDefaultBranch(files: ["unrelated.txt": "u1"])

      // 既定 branch 側は [unrelated(新), squash(古)]。上限 1 は squash に届かない。
      #expect(try await repository.branchMergeStatus("topic", scanLimit: 1) == .unmerged)
      #expect(try await repository.branchMergeStatus("topic", scanLimit: 2) == .merged)
    }
  }

  @Test("共通祖先を持たない branch は判定不能ではなく unmerged")
  func treatsUnrelatedHistoryAsUnmerged() async throws {
    try await withGitRepository { repository in
      // 共通祖先が無いと `merge-base` は rc 1 / 空出力を返す (git 2.50.1 実測)。異常終了と
      // 同じ扱いにすると、修正前は `.unmerged` だった branch が `.unknown` へ格下げされる。
      try await repository.addOrphanWorktree("alien", files: ["alien.txt": "x1"])

      #expect(try await repository.branchMergeStatus("alien") == .unmerged)
    }
  }

  @Test("既定 branch が無関係な履歴を取り込んでいても、未マージ branch を merged にしない")
  func keepsUnmergedBranchUnmergedWithParentlessCommitInRange() async throws {
    try await withGitRepository { repository in
      // 取り込まれた root commit は親を持たず、「既定 branch へ何を持ち込んだか」を第1親との
      // 差では書けない。走査から外す側が `.merged` に倒れると、この branch が消せてしまう。
      try await repository.addBranchWorktree("topic", commits: [["a.txt": "a1"]])
      try await repository.addOrphanWorktree("alien", files: ["alien.txt": "x1"])
      try await repository.git(
        ["merge", "-q", "--allow-unrelated-histories", "-m", "merge alien", "alien"])

      #expect(try await repository.branchMergeStatus("topic") == .unmerged)
    }
  }

  @Test("既定 branch 側の merge commit は第1親との差で突き合わせる")
  func comparesMergeCommitAgainstItsFirstParent() async throws {
    try await withGitRepository { repository in
      // 同じ最終内容を別の刻み方で持つ branch が `--no-ff` で入った形。合成差分と一致するのは
      // merge commit の第1親側だけで、第2親側の差は空になる。
      try await repository.addBranchWorktree(
        "topic", commits: [["a.txt": "a1"], ["a.txt": "a1\na2"]])
      try await repository.addBranchWorktree(
        "mirror", commits: [["a.txt": "a0"], ["a.txt": "a1\na2"]])
      try await repository.git(["merge", "-q", "--no-ff", "-m", "merge mirror", "mirror"])

      #expect(try await repository.branchMergeStatus("topic") == .merged)
    }
  }
}

extension GitTestRepository {
  /// `commits` の 1 要素が 1 commit で、値はそのパスへ書く内容。
  fileprivate func addBranchWorktree(
    _ branch: String, commits: [[String: String]]
  ) async throws {
    try await git(["worktree", "add", "-q", "-b", branch, "../\(branch)"])
    for files in commits {
      try await commitOnBranchWorktree(branch, files: files)
    }
  }

  /// 既定 branch と共通祖先を持たない branch。`--orphan` に commit-ish は渡せない
  /// (git 2.50.1 実測: `fatal: option '--orphan' and commit-ish cannot be used together`)。
  fileprivate func addOrphanWorktree(_ branch: String, files: [String: String]) async throws {
    try await git(["worktree", "add", "-q", "--orphan", "-b", branch, "../\(branch)"])
    try await commitOnBranchWorktree(branch, files: files)
  }

  fileprivate func commitOnBranchWorktree(
    _ branch: String, files: [String: String]
  ) async throws {
    try write(files, in: root.appending(path: branch))
    try await commitAll(message: "commit on \(branch)", in: branch)
  }

  fileprivate func removeOnBranchWorktree(_ branch: String, file: String) async throws {
    try FileManager.default.removeItem(at: root.appending(path: "\(branch)/\(file)"))
    try await commitAll(message: "remove \(file)", in: branch)
  }

  fileprivate func commitOnDefaultBranch(files: [String: String]) async throws {
    try write(files, in: mainWorktree)
    try await commitAll(message: "commit on main", in: nil)
  }

  fileprivate func squashMerge(_ branch: String) async throws {
    // `merge --squash` は index と作業ツリーだけを更新して HEAD を進めない。GitHub の
    // squash merge と同じく commit は明示的に作る。
    try await git(["merge", "-q", "--squash", branch])
    try await git(["commit", "-q", "-m", "squash \(branch)"])
  }

  fileprivate func branchMergeStatus(
    _ branch: String, scanLimit: Int = GitCloseSafetyInspector.defaultSquashScanCommitLimit
  ) async throws -> BranchMergeStatus {
    let target = try #require(try await detector().scan().detected.first { $0.branch == branch })
    let result = await GitCloseSafetyInspector(
      runner: try runner(globalConfig: "", in: branch), target: target,
      squashScanCommitLimit: scanLimit
    ).inspect(projectRootBranch: "main")
    #expect(result.failures.isEmpty)
    return result.report.inspection.branchMerge
  }

  private func write(_ files: [String: String], in directory: URL) throws {
    for (name, contents) in files {
      try (contents + "\n").write(
        to: directory.appending(path: name), atomically: true, encoding: .utf8)
    }
  }

  private func commitAll(message: String, in worktreeName: String?) async throws {
    try await git(["add", "-A"], in: worktreeName)
    try await git(["commit", "-q", "-m", message], in: worktreeName)
  }
}

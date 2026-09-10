import Foundation
import TerminalCore
import Testing

@testable import Adapters

/// 実 git に対して §3.4 の「detached HEAD の worktree では Close そのものを拒否する」
/// (確定 2026-09-08) を固定する。
///
/// fixture では固定できない。detached HEAD が無警告で通っていた原因は、`worktree list` が
/// `branch` 行を吐かず `status --porcelain=v2` の entries も 0 件になるという**実 git の
/// 出力の組み合わせ**であり、その2つを同じ1つの worktree から取れることまで含めて確かめないと、
/// 検査が全部 `absent` / `notApplicable` に落ちる経路を再現できない。
@Suite("§3.4 実 git の detached HEAD worktree に対する Close")
struct GitDetachedHeadCloseIntegrationTests {
  private static let everyChoice: [WorktreeCloseChoice] = [
    .hideFromUI, .terminateSession(.keepWorktree),
    .terminateSession(.removeWorktree(.keepBranch)),
    .terminateSession(.removeWorktree(.deleteBranch)),
  ]

  @Test("detached HEAD に積んだ commit を持つ worktree は、どの選択肢でも Close できない")
  func rejectsCloseForDetachedHeadWithCommits() async throws {
    try await withGitRepository { repository in
      try await repository.git(["worktree", "add", "-q", "--detach", "../wt-detached", "HEAD"])
      let lost = repository.root.appending(path: "wt-detached/lost.txt")
      try "lost\n".write(to: lost, atomically: true, encoding: .utf8)
      try await repository.git(["add", "-A"], in: "wt-detached")
      try await repository.git(["commit", "-q", "-m", "unreachable"], in: "wt-detached")

      let target = try #require(
        try await repository.detector().scan().detected.first { !$0.isProjectRoot })
      #expect(target.branch == nil)

      let inspector = GitCloseSafetyInspector(
        runner: try repository.runner(globalConfig: "", in: "wt-detached"), target: target)
      let result = await inspector.inspect(projectRootBranch: "main")

      // 未commit変更と ignored は実際に無いので `absent` が正しい。残る2検査を `notApplicable`
      // へ丸めると4検査すべてが無警告になり、この commit が黙って到達不能になる。
      #expect(result.report.inspection.uncommittedChanges == .absent)
      #expect(result.report.inspection.ignoredFiles == .absent)
      #expect(result.report.inspection.unpushedCommits == .unknown)
      #expect(result.report.inspection.branchMerge == .unknown)
      #expect(result.report.defaultBranch == .unresolved(reason: .detachedHead))
      #expect(result.failures.isEmpty)

      let confirmation = WorktreeRemovalConfirmation(
        report: result.report, continuation: .forcingAcknowledgedWarnings)
      for choice in Self.everyChoice {
        #expect(throws: WorktreeClosePlanError.detachedHeadIsNotClosable) {
          try planWorktreeClose(
            worktree: target, choice: choice, confirmation: confirmation)
        }
      }

    }
  }

  @Test("中断中の rebase を持つ worktree は、どの選択肢でも Close できない")
  func rejectsCloseForInterruptedRebase() async throws {
    try await withGitRepository { repository in
      try await repository.git(["worktree", "add", "-q", "-b", "wt-rebase", "../wt-rebase"])
      try "topic\n".write(
        to: repository.root.appending(path: "wt-rebase/t.txt"), atomically: true, encoding: .utf8)
      try await repository.git(["add", "-A"], in: "wt-rebase")
      try await repository.git(["commit", "-q", "-m", "topic"], in: "wt-rebase")

      // `--exec false` は commit ごとに rc≠0 の command を走らせるので、rebase は必ず途中で止まる。
      let rebase = try await repository.gitExitCode(
        ["rebase", "--exec", "false", "main"], in: "wt-rebase")
      #expect(rebase.exitCode != 0)

      let target = try #require(
        try await repository.detector().scan().detected.first { !$0.isProjectRoot })
      // 停止中の rebase は HEAD を detach したままにする (git 2.50.1 実測: `worktree list
      // --porcelain` は `branch` 行ではなく `detached` を吐く)。branch を持っていた worktree でも
      // 起きるので、detached の判定を「作成時に --detach したか」で代用できない。
      #expect(target.branch == nil)
      let rebaseState = "\(target.identity.rawValue)/rebase-merge"
      #expect(FileManager.default.fileExists(atPath: rebaseState))

      let inspector = GitCloseSafetyInspector(
        runner: try repository.runner(globalConfig: "", in: "wt-rebase"), target: target)
      let result = await inspector.inspect(projectRootBranch: "main")

      #expect(result.report.inspection.unpushedCommits == .unknown)
      #expect(result.report.inspection.branchMerge == .unknown)

      let confirmation = WorktreeRemovalConfirmation(
        report: result.report, continuation: .forcingAcknowledgedWarnings)
      for choice in Self.everyChoice {
        #expect(throws: WorktreeClosePlanError.detachedHeadIsNotClosable) {
          try planWorktreeClose(
            worktree: target, choice: choice, confirmation: confirmation)
        }
      }

    }
  }
}

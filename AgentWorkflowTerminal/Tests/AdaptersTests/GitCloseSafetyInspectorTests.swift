import Foundation
import TerminalCore
import Testing

@testable import Adapters

@Suite("Close 前の git 安全確認 (設計書 §3.4)")
struct GitCloseSafetyInspectorTests {
  @Test("public 初期化子の検査 report は検査対象の identity を返す")
  func publicInitializerReportUsesTargetIdentity() async throws {
    let inspectedTarget = try target(identity: "/repo/.git/worktrees/public", branch: "topic")
    let stub = CloseInspectionProcessStub { _ in
      .success(
        .init(exitCode: 0, stdout: "# branch.oid abc\0# branch.head (detached)\0", stderr: ""))
    }
    let inspector = try GitCloseSafetyInspector(
      target: inspectedTarget, processRunner: stub,
      executableCandidates: [URL(fileURLWithPath: "/usr/bin/git")])

    let result = await inspector.inspect(projectRootBranch: "main")

    #expect(result.report.worktree == inspectedTarget.identity)
  }

  @Test("internal 初期化子の検査 report は検査対象の identity を返す")
  func internalInitializerReportUsesTargetIdentity() async throws {
    let inspectedTarget = try target(identity: "/repo/.git/worktrees/internal", branch: nil)
    let stub = CloseInspectionProcessStub { _ in
      .success(
        .init(exitCode: 0, stdout: "# branch.oid abc\0# branch.head (detached)\0", stderr: ""))
    }
    let inspector = GitCloseSafetyInspector(
      runner: try runner(stub), target: inspectedTarget)

    let result = await inspector.inspect(projectRootBranch: "main")

    #expect(result.report.worktree == inspectedTarget.identity)
  }

  @Test("完全修飾された local branch ref を revision として受け付ける")
  func acceptsFullyQualifiedBranchRevision() {
    #expect(GitRevision("refs/heads/x")?.rawValue == "refs/heads/x")
  }

  @Test("refs/ で始まる短縮 branch 名にも refs/heads/ を付ける")
  func qualifiesBranchNameStartingWithRefs() async throws {
    let stub = CloseInspectionProcessStub { arguments in
      switch commandArguments(arguments) {
      case GitReadCommand.status().arguments, GitReadCommand.status(includeIgnored: true).arguments:
        .success(
          .init(
            exitCode: 0, stdout: "# branch.oid abc\0# branch.head topic\0", stderr: ""))
      case GitReadCommand.stashList().arguments:
        .success(.init(exitCode: 0, stdout: "", stderr: ""))
      case GitReadCommand.originHead().arguments:
        .success(.init(exitCode: 1, stdout: "", stderr: ""))
      case ["rev-parse", "--verify", "--quiet", "refs/heads/refs/foo"]:
        .success(tipOutput(fixtureTipHex))
      case ["merge-base", "--is-ancestor", fixtureTipHex, fixtureDefaultTipHex]:
        .success(.init(exitCode: 1, stdout: "", stderr: ""))
      default:
        squashScanWithoutCandidates(commandArguments(arguments))
      }
    }
    let inspector = GitCloseSafetyInspector(
      runner: try runner(stub), target: try target(branch: "refs/foo"))

    let result = await inspector.inspect(projectRootBranch: "main")

    #expect(result.report.defaultBranch == .projectRoot(branch: "main"))
    #expect(result.report.inspection.branchMerge == .unmerged)
    #expect(result.failures.isEmpty)
  }

  @Test("refs/heads/ で始まる短縮 branch 名も常に修飾する")
  func qualifiesBranchNameStartingWithRefsHeads() async throws {
    let stub = CloseInspectionProcessStub { arguments in
      switch commandArguments(arguments) {
      case GitReadCommand.status().arguments, GitReadCommand.status(includeIgnored: true).arguments:
        .success(
          .init(
            exitCode: 0, stdout: "# branch.oid abc\0# branch.head refs/heads/x\0", stderr: ""))
      case GitReadCommand.stashList().arguments:
        .success(.init(exitCode: 0, stdout: "", stderr: ""))
      case GitReadCommand.originHead().arguments:
        .success(.init(exitCode: 1, stdout: "", stderr: ""))
      case ["rev-parse", "--verify", "--quiet", "refs/heads/refs/heads/x"]:
        .success(tipOutput(fixtureTipHex))
      case ["merge-base", "--is-ancestor", fixtureTipHex, fixtureDefaultTipHex]:
        .success(.init(exitCode: 1, stdout: "", stderr: ""))
      default:
        squashScanWithoutCandidates(commandArguments(arguments))
      }
    }
    let inspector = GitCloseSafetyInspector(
      runner: try runner(stub), target: try target(branch: "refs/heads/x"))

    let result = await inspector.inspect(projectRootBranch: "main")

    #expect(result.report.inspection.branchMerge == .unmerged)
    #expect(result.failures.isEmpty)
  }

  @Test("untracked と upstream 不在を警告し、origin/HEAD へのマージを判定する")
  func inspectsWarningsAndOriginDefaultBranch() async throws {
    let stub = CloseInspectionProcessStub { arguments in
      switch commandArguments(arguments) {
      case GitReadCommand.status().arguments, GitReadCommand.status(includeIgnored: true).arguments:
        .success(
          .init(
            exitCode: 0,
            stdout: "# branch.oid abc\0# branch.head topic\0? new.txt\0",
            stderr: ""))
      case GitReadCommand.stashList().arguments:
        .success(.init(exitCode: 0, stdout: "", stderr: ""))
      case GitReadCommand.originHead().arguments:
        .success(.init(exitCode: 0, stdout: "refs/remotes/origin/main\n", stderr: ""))
      case ["rev-parse", "--verify", "--quiet", "refs/heads/topic"]:
        .success(tipOutput(fixtureTipHex))
      case ["merge-base", "--is-ancestor", fixtureTipHex, fixtureDefaultTipHex]:
        .success(.init(exitCode: 0, stdout: "", stderr: ""))
      default:
        defaultBranchTipOrUnexpected(commandArguments(arguments))
      }
    }
    let inspector = GitCloseSafetyInspector(
      runner: try runner(stub), target: try target(branch: "topic"))

    let result = await inspector.inspect(projectRootBranch: nil)

    #expect(result.report.inspection.uncommittedChanges == .present)
    #expect(result.report.inspection.ignoredFiles == .absent)
    #expect(result.report.inspection.unpushedCommits == .present)
    #expect(try merged(.ancestor) == result.report.inspection.branchMerge)
    #expect(result.report.defaultBranch == .originHead(branch: "main"))
    #expect(result.failures.isEmpty)
  }

  @Test("origin/HEAD 不在なら Project Root の branch へフォールバックする")
  func fallsBackToProjectRootBranch() async throws {
    let stub = CloseInspectionProcessStub { arguments in
      switch commandArguments(arguments) {
      case GitReadCommand.status().arguments, GitReadCommand.status(includeIgnored: true).arguments:
        .success(
          .init(
            exitCode: 0,
            stdout:
              "# branch.oid abc\0# branch.head topic\0# branch.upstream origin/topic\0# branch.ab +0 -2\0",
            stderr: ""))
      case GitReadCommand.stashList().arguments:
        .success(.init(exitCode: 0, stdout: "", stderr: ""))
      case GitReadCommand.originHead().arguments:
        .success(.init(exitCode: 1, stdout: "", stderr: ""))
      case ["rev-parse", "--verify", "--quiet", "refs/heads/topic"]:
        .success(tipOutput(fixtureTipHex))
      case ["merge-base", "--is-ancestor", fixtureTipHex, fixtureDefaultTipHex]:
        .success(.init(exitCode: 1, stdout: "", stderr: ""))
      default:
        squashScanWithoutCandidates(commandArguments(arguments))
      }
    }
    let inspector = GitCloseSafetyInspector(
      runner: try runner(stub), target: try target(branch: "topic"))

    let result = await inspector.inspect(projectRootBranch: "main")

    #expect(result.report.inspection.uncommittedChanges == .absent)
    #expect(result.report.inspection.ignoredFiles == .absent)
    #expect(result.report.inspection.unpushedCommits == .absent)
    #expect(result.report.inspection.branchMerge == .unmerged)
    #expect(result.report.defaultBranch == .projectRoot(branch: "main"))
    #expect(result.failures.isEmpty)
  }

  @Test("detached HEAD の push と merge は判定不能であり、問う必要が無いのではない")
  func reportsBranchChecksAsUnknownForDetachedHead() async throws {
    let stub = CloseInspectionProcessStub { arguments in
      // detached でも branch を特定できない stash は数えるので `stash list` は読む (#640)。
      if commandArguments(arguments) == GitReadCommand.stashList().arguments {
        return .success(.init(exitCode: 0, stdout: "", stderr: ""))
      }
      #expect(
        [GitReadCommand.status().arguments, GitReadCommand.status(includeIgnored: true).arguments]
          .contains(commandArguments(arguments)))
      return .success(
        .init(
          exitCode: 0, stdout: "# branch.oid abc\0# branch.head (detached)\0", stderr: ""))
    }
    let inspector = GitCloseSafetyInspector(
      runner: try runner(stub), target: try target(branch: nil))

    let result = await inspector.inspect(projectRootBranch: "main")

    #expect(result.report.inspection.uncommittedChanges == .absent)
    #expect(result.report.inspection.ignoredFiles == .absent)
    #expect(result.report.inspection.unpushedCommits == .unknown)
    #expect(result.report.inspection.branchMerge == .unknown)
    #expect(result.report.defaultBranch == .unresolved(reason: .detachedHead))
    #expect(result.failures.isEmpty)
  }

  @Test("ignored を独立して警告し、upstream より先行した commit も警告する")
  func ignoresIgnoredEntriesAndDetectsAheadCommit() async throws {
    let results = CloseInspectionResultQueue([
      .success(
        .init(
          exitCode: 0,
          stdout:
            "# branch.oid abc\0# branch.head topic\0# branch.upstream origin/topic\0# branch.ab +2 -0\0",
          stderr: "")),
      .success(
        .init(
          exitCode: 0,
          stdout:
            "# branch.oid abc\0# branch.head topic\0# branch.upstream origin/topic\0# branch.ab +2 -0\0! generated\0",
          stderr: "")),
      .success(.init(exitCode: 0, stdout: "", stderr: "")),
      .success(.init(exitCode: 1, stdout: "", stderr: "")),
    ])
    let inspector = GitCloseSafetyInspector(
      runner: try runner(results), target: try target(branch: "topic"))

    let result = await inspector.inspect(projectRootBranch: nil)

    #expect(result.report.inspection.uncommittedChanges == .absent)
    #expect(result.report.inspection.ignoredFiles == .present)
    #expect(result.report.inspection.unpushedCommits == .present)
    #expect(result.report.inspection.branchMerge == .unknown)
    #expect(result.report.defaultBranch == .unresolved(reason: .originHeadMissing))
  }

  @Test("ignored 側の出力上限超過を他の3検査へ波及させない")
  func isolatesIgnoredStatusFailure() async throws {
    let stub = CloseInspectionProcessStub { arguments in
      switch commandArguments(arguments) {
      case GitReadCommand.status().arguments:
        .success(
          .init(
            exitCode: 0,
            stdout:
              "# branch.oid abc\0# branch.head topic\0# branch.upstream origin/topic\0# branch.ab +0 -0\0",
            stderr: ""))
      case GitReadCommand.status(includeIgnored: true).arguments:
        .failure(.outputLimitExceeded(limit: ProcessRunLimits.defaultOutputBytes))
      case GitReadCommand.stashList().arguments:
        .success(.init(exitCode: 0, stdout: "", stderr: ""))
      case GitReadCommand.originHead().arguments:
        .success(.init(exitCode: 0, stdout: "refs/remotes/origin/main\n", stderr: ""))
      case ["rev-parse", "--verify", "--quiet", "refs/heads/topic"]:
        .success(tipOutput(fixtureTipHex))
      case ["merge-base", "--is-ancestor", fixtureTipHex, fixtureDefaultTipHex]:
        .success(.init(exitCode: 0, stdout: "", stderr: ""))
      default:
        defaultBranchTipOrUnexpected(commandArguments(arguments))
      }
    }
    let inspector = GitCloseSafetyInspector(
      runner: try runner(stub), target: try target(branch: "topic"))

    let result = await inspector.inspect(projectRootBranch: nil)

    #expect(result.report.inspection.uncommittedChanges == .absent)
    #expect(result.report.inspection.ignoredFiles == .unknown)
    #expect(result.report.inspection.unpushedCommits == .absent)
    #expect(try merged(.ancestor) == result.report.inspection.branchMerge)
    #expect(result.failures.map(\.check) == [.ignoredFiles])
  }

  @Test("設定済み upstream の追跡 ref 消失を push 済みへ丸めない")
  func reportsMissingTrackingBranchAsKnownState() async throws {
    let results = CloseInspectionResultQueue([
      .success(
        .init(
          exitCode: 0,
          stdout:
            "# branch.oid abc\0# branch.head topic\0# branch.upstream origin/topic\0",
          stderr: "")),
      .success(
        .init(
          exitCode: 0,
          stdout:
            "# branch.oid abc\0# branch.head topic\0# branch.upstream origin/topic\0",
          stderr: "")),
      .success(.init(exitCode: 0, stdout: "", stderr: "")),
      .success(.init(exitCode: 1, stdout: "", stderr: "")),
    ])
    let inspector = GitCloseSafetyInspector(
      runner: try runner(results), target: try target(branch: "topic"))

    let result = await inspector.inspect(projectRootBranch: nil)

    #expect(result.report.inspection.unpushedCommits == .aheadUnknownWithoutTrackingReference)
    #expect(result.failures.isEmpty)
  }

  @Test("origin/HEAD の実行異常では Project Root へフォールバックしない")
  func doesNotFallbackAfterOriginHeadFailure() async throws {
    let results = CloseInspectionResultQueue([
      .success(
        .init(
          exitCode: 0,
          stdout: "# branch.oid abc\0# branch.head topic\0",
          stderr: "")),
      .success(
        .init(
          exitCode: 0,
          stdout: "# branch.oid abc\0# branch.head topic\0",
          stderr: "")),
      .success(.init(exitCode: 0, stdout: "", stderr: "")),
      .success(.init(exitCode: 128, stdout: "", stderr: "fatal: broken ref\n")),
      .success(.init(exitCode: 0, stdout: "", stderr: "")),
    ])
    let inspector = GitCloseSafetyInspector(
      runner: try runner(results), target: try target(branch: "topic"))

    let result = await inspector.inspect(projectRootBranch: "main")

    #expect(result.report.defaultBranch == .unresolved(reason: .lookupFailed))
    #expect(result.report.inspection.branchMerge == .unknown)
    #expect(result.failures.map(\.check) == [.branchMerge])
    #expect(
      !isBranchDeletionAvailable(
        targetBranch: "topic", defaultBranch: result.report.defaultBranch,
        merge: result.report.inspection.branchMerge))
  }

  @Test("解釈不能な origin/HEAD の値では Project Root へフォールバックしない")
  func doesNotFallbackAfterInvalidOriginHead() async throws {
    let results = CloseInspectionResultQueue([
      .success(
        .init(
          exitCode: 0,
          stdout: "# branch.oid abc\0# branch.head topic\0",
          stderr: "")),
      .success(
        .init(
          exitCode: 0,
          stdout: "# branch.oid abc\0# branch.head topic\0",
          stderr: "")),
      .success(.init(exitCode: 0, stdout: "", stderr: "")),
      .success(.init(exitCode: 0, stdout: "refs/heads/main\n", stderr: "")),
      .success(.init(exitCode: 0, stdout: "", stderr: "")),
    ])
    let inspector = GitCloseSafetyInspector(
      runner: try runner(results), target: try target(branch: "topic"))

    let result = await inspector.inspect(projectRootBranch: "main")

    #expect(
      result.report.defaultBranch
        == .unresolved(reason: .invalidOriginHead("refs/heads/main")))
    #expect(result.report.inspection.branchMerge == .unknown)
    #expect(result.failures.isEmpty)
    #expect(
      !isBranchDeletionAvailable(
        targetBranch: "topic", defaultBranch: result.report.defaultBranch,
        merge: result.report.inspection.branchMerge))
  }

  @Test("実在する `(detached)` branch を upstream 無しとして警告する")
  func treatsNamedDetachedBranchAsBranch() async throws {
    let results = CloseInspectionResultQueue([
      .success(
        .init(
          exitCode: 0, stdout: "# branch.oid abc\0# branch.head (detached)\0", stderr: "")),
      .success(
        .init(
          exitCode: 0, stdout: "# branch.oid abc\0# branch.head (detached)\0", stderr: "")),
      .success(.init(exitCode: 0, stdout: "", stderr: "")),
      .success(.init(exitCode: 1, stdout: "", stderr: "")),
    ])
    let inspector = GitCloseSafetyInspector(
      runner: try runner(results), target: try target(branch: "(detached)"))

    let result = await inspector.inspect(projectRootBranch: nil)

    #expect(result.report.inspection.unpushedCommits == .present)
  }

  @Test("status の失敗後も merge 検査を返す")
  func preservesPartialSuccess() async throws {
    let statusError = ProcessRunnerError.timedOut(exitCode: nil, stdout: "", stderr: "")
    let stub = CloseInspectionProcessStub { arguments in
      switch commandArguments(arguments) {
      case GitReadCommand.status().arguments:
        .failure(statusError)
      case GitReadCommand.status(includeIgnored: true).arguments:
        .success(.init(exitCode: 0, stdout: "# branch.oid abc\0# branch.head topic\0", stderr: ""))
      case GitReadCommand.stashList().arguments:
        .success(.init(exitCode: 0, stdout: "", stderr: ""))
      case GitReadCommand.originHead().arguments:
        .success(.init(exitCode: 0, stdout: "refs/remotes/origin/main\n", stderr: ""))
      case ["rev-parse", "--verify", "--quiet", "refs/heads/topic"]:
        .success(tipOutput(fixtureTipHex))
      case ["merge-base", "--is-ancestor", fixtureTipHex, fixtureDefaultTipHex]:
        .success(.init(exitCode: 0, stdout: "", stderr: ""))
      default:
        defaultBranchTipOrUnexpected(commandArguments(arguments))
      }
    }
    let inspector = GitCloseSafetyInspector(
      runner: try runner(stub), target: try target(branch: "topic"))

    let result = await inspector.inspect(projectRootBranch: nil)

    #expect(result.report.inspection.uncommittedChanges == .unknown)
    #expect(result.report.inspection.ignoredFiles == .absent)
    #expect(result.report.inspection.unpushedCommits == .unknown)
    #expect(try merged(.ancestor) == result.report.inspection.branchMerge)
    #expect(
      result.failures.map(\.check) == [.uncommittedChanges, .unpushedCommits])
  }
}

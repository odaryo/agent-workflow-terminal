import TerminalCore
import Testing

@testable import AgentWorkflowTerminalApp

@Suite("§3.4 Close 実行前の対象照合")
struct WorktreeCloseSessionTests {
  @Test(
    "選択肢1・2は detached と別 branch でも通す",
    arguments: [
      WorktreeCloseOption.hideFromUI, .terminateSession,
    ])
  func allowsBranchChangesWhenKeepingWorktree(option: WorktreeCloseOption) throws {
    for planned in [nil, "topic"] {
      for current in [nil, "other"] {
        #expect(
          WorktreeCloseSession.matchesInspectedTarget(
            current: try target(branch: current), target: try target(branch: planned),
            option: option))
      }
    }
  }

  @Test(
    "選択肢3・4は両方の branch が非 nil でバイト一致する場合だけ通す",
    arguments: [
      WorktreeCloseOption.removeWorktree, .deleteBranch,
    ])
  func requiresMatchingBranchesWhenRemovingWorktree(option: WorktreeCloseOption) throws {
    let planned = try target(branch: "topic")
    #expect(
      WorktreeCloseSession.matchesInspectedTarget(current: planned, target: planned, option: option)
    )
    #expect(
      !WorktreeCloseSession.matchesInspectedTarget(
        current: try target(branch: "other"), target: planned, option: option))
    for branch in [nil, "topic"] {
      #expect(
        !WorktreeCloseSession.matchesInspectedTarget(
          current: try target(branch: nil), target: try target(branch: branch), option: option))
      #expect(
        !WorktreeCloseSession.matchesInspectedTarget(
          current: try target(branch: branch), target: try target(branch: nil), option: option))
    }
    #expect(
      !WorktreeCloseSession.matchesInspectedTarget(
        current: try target(branch: "cafe\u{301}"), target: try target(branch: "café"),
        option: option))
  }

  @Test("すべての選択肢で到達可能性とパスのバイト一致を確かめる", arguments: WorktreeCloseOption.allCases)
  func requiresReachableMatchingPath(option: WorktreeCloseOption) throws {
    let planned = try target(branch: "topic", path: "/repo/café")
    #expect(
      WorktreeCloseSession.matchesInspectedTarget(current: planned, target: planned, option: option)
    )
    #expect(
      !WorktreeCloseSession.matchesInspectedTarget(
        current: try target(branch: "topic", path: planned.worktreePath, isReachable: false),
        target: planned, option: option))
    for path in ["/repo/other", "/repo/cafe\u{301}"] {
      #expect(
        !WorktreeCloseSession.matchesInspectedTarget(
          current: try target(branch: "topic", path: path), target: planned, option: option))
    }
  }

  private func target(
    branch: String?, path: String = "/repo/worktree", isReachable: Bool = true
  ) throws -> DetectedWorktree {
    DetectedWorktree(
      identity: try #require(WorktreeIdentity(rawValue: "/repo/admin")),
      worktreePath: path, branch: branch, isProjectRoot: false, isReachable: isReachable)
  }
}

import TerminalCore
import Testing

@Suite("Close の選択肢と安全確認 (設計書 §3.4)")
struct WorktreeCloseTests {
  @Test("4択の包含関係を表現する")
  func representsNestedChoices() {
    let choices: [WorktreeCloseChoice] = [
      .hideFromUI,
      .terminateSession(.keepWorktree),
      .terminateSession(.removeWorktree(.keepBranch)),
      .terminateSession(.removeWorktree(.deleteBranch)),
    ]

    #expect(Set(choices).count == 4)
  }

  @Test("branch 削除は既定 branch とは異なるマージ済み branch だけに許す")
  func permitsBranchDeletionOnlyForMergedNondefaultBranch() {
    #expect(
      isBranchDeletionAvailable(
        targetBranch: "topic", defaultBranch: "main", merge: .merged))
    #expect(
      !isBranchDeletionAvailable(
        targetBranch: "topic", defaultBranch: "main", merge: .unmerged))
    #expect(
      !isBranchDeletionAvailable(
        targetBranch: "topic", defaultBranch: "main", merge: .unknown))
    #expect(
      !isBranchDeletionAvailable(
        targetBranch: nil, defaultBranch: "main", merge: .notApplicable))
    #expect(
      !isBranchDeletionAvailable(
        targetBranch: "topic", defaultBranch: nil, merge: .unknown))
    #expect(
      !isBranchDeletionAvailable(
        targetBranch: "main", defaultBranch: "main", merge: .merged))
  }
}

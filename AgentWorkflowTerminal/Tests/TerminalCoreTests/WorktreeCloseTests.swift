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
  func permitsBranchDeletionOnlyForMergedNondefaultBranch() throws {
    #expect(
      isBranchDeletionAvailable(
        targetBranch: "topic", defaultBranch: .originHead(branch: "main"),
        merge: try merged(.ancestor)
      ))
    #expect(
      isBranchDeletionAvailable(
        targetBranch: "topic", defaultBranch: .originHead(branch: "main"),
        merge: try merged(.squash)))
    #expect(
      !isBranchDeletionAvailable(
        targetBranch: "topic", defaultBranch: .originHead(branch: "main"), merge: .unmerged))
    #expect(
      !isBranchDeletionAvailable(
        targetBranch: "topic", defaultBranch: .originHead(branch: "main"), merge: .unknown))
    #expect(
      !isBranchDeletionAvailable(
        targetBranch: nil, defaultBranch: .originHead(branch: "main"), merge: .notApplicable))
    #expect(
      !isBranchDeletionAvailable(
        targetBranch: "topic",
        defaultBranch: .unresolved(reason: .originHeadMissing), merge: .unknown))
    #expect(
      !isBranchDeletionAvailable(
        targetBranch: "main", defaultBranch: .projectRoot(branch: "main"),
        merge: try merged(.squash)))
  }

  @Test(
    "commit の OID は git が出力する完全な小文字 16 進だけを受け付ける",
    arguments: [
      (String(repeating: "a", count: 40), true), (String(repeating: "0", count: 64), true),
      (String(repeating: "a", count: 39), false), (String(repeating: "a", count: 41), false),
      (String(repeating: "A", count: 40), false), (String(repeating: "g", count: 40), false),
      (String(repeating: "a", count: 40) + "\n", false), ("", false),
    ])
  func acceptsOnlyFullLowercaseObjectIDs(value: String, isValid: Bool) {
    #expect((CommitObjectID(value) != nil) == isValid)
  }
}

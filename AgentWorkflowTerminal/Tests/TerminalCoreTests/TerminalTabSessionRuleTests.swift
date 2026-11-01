import TerminalCore
import Testing

@Suite("タブのsessionの有無と同じディレクトリのタブ枚数による判定 (設計書 §3.3)")
struct TerminalTabSessionRuleTests {
  struct AfterExitCase: Sendable {
    let sessionExists: Bool?
    let tabsInDirectory: Int
    let expected: TerminalTabSessionRule.AfterExit
  }

  struct OnOpenCase: Sendable {
    let sessionExists: Bool?
    let tabsInDirectory: Int
    let isNewlyAdded: Bool
    let expected: TerminalTabSessionRule.OnOpen
  }

  @Test(
    "attach終了後はsessionが無く同じディレクトリに他のタブがある場合だけ閉じる",
    arguments: [
      .init(sessionExists: true, tabsInDirectory: 0, expected: .offerReattach),
      .init(sessionExists: true, tabsInDirectory: 1, expected: .offerReattach),
      .init(sessionExists: true, tabsInDirectory: 2, expected: .offerReattach),
      .init(sessionExists: true, tabsInDirectory: 5, expected: .offerReattach),
      .init(sessionExists: false, tabsInDirectory: 0, expected: .offerReattach),
      .init(sessionExists: false, tabsInDirectory: 1, expected: .offerReattach),
      .init(sessionExists: false, tabsInDirectory: 2, expected: .closeTab),
      .init(sessionExists: false, tabsInDirectory: 5, expected: .closeTab),
      .init(sessionExists: nil, tabsInDirectory: 0, expected: .offerReattach),
      .init(sessionExists: nil, tabsInDirectory: 1, expected: .offerReattach),
      .init(sessionExists: nil, tabsInDirectory: 2, expected: .offerReattach),
      .init(sessionExists: nil, tabsInDirectory: 5, expected: .offerReattach),
    ] as [AfterExitCase]
  )
  func afterExit(testCase: AfterExitCase) {
    #expect(
      TerminalTabSessionRule.afterExit(
        sessionExists: testCase.sessionExists,
        tabsInDirectory: testCase.tabsInDirectory
      ) == testCase.expected
    )
  }

  @Test(
    "開く際は新規追加でなくsessionが無く同じディレクトリに他のタブがある場合だけ閉じる",
    arguments: [
      .init(sessionExists: true, tabsInDirectory: 0, isNewlyAdded: true, expected: .attachOrCreate),
      .init(sessionExists: true, tabsInDirectory: 1, isNewlyAdded: true, expected: .attachOrCreate),
      .init(sessionExists: true, tabsInDirectory: 2, isNewlyAdded: true, expected: .attachOrCreate),
      .init(sessionExists: true, tabsInDirectory: 5, isNewlyAdded: true, expected: .attachOrCreate),
      .init(
        sessionExists: false, tabsInDirectory: 0, isNewlyAdded: true, expected: .attachOrCreate),
      .init(
        sessionExists: false, tabsInDirectory: 1, isNewlyAdded: true, expected: .attachOrCreate),
      .init(
        sessionExists: false, tabsInDirectory: 2, isNewlyAdded: true, expected: .attachOrCreate),
      .init(
        sessionExists: false, tabsInDirectory: 5, isNewlyAdded: true, expected: .attachOrCreate),
      .init(sessionExists: nil, tabsInDirectory: 0, isNewlyAdded: true, expected: .attachOrCreate),
      .init(sessionExists: nil, tabsInDirectory: 1, isNewlyAdded: true, expected: .attachOrCreate),
      .init(sessionExists: nil, tabsInDirectory: 2, isNewlyAdded: true, expected: .attachOrCreate),
      .init(sessionExists: nil, tabsInDirectory: 5, isNewlyAdded: true, expected: .attachOrCreate),
      .init(
        sessionExists: true, tabsInDirectory: 0, isNewlyAdded: false, expected: .attachOrCreate),
      .init(
        sessionExists: true, tabsInDirectory: 1, isNewlyAdded: false, expected: .attachOrCreate),
      .init(
        sessionExists: true, tabsInDirectory: 2, isNewlyAdded: false, expected: .attachOrCreate),
      .init(
        sessionExists: true, tabsInDirectory: 5, isNewlyAdded: false, expected: .attachOrCreate),
      .init(
        sessionExists: false, tabsInDirectory: 0, isNewlyAdded: false, expected: .attachOrCreate),
      .init(
        sessionExists: false, tabsInDirectory: 1, isNewlyAdded: false, expected: .attachOrCreate),
      .init(sessionExists: false, tabsInDirectory: 2, isNewlyAdded: false, expected: .closeTab),
      .init(sessionExists: false, tabsInDirectory: 5, isNewlyAdded: false, expected: .closeTab),
      .init(sessionExists: nil, tabsInDirectory: 0, isNewlyAdded: false, expected: .attachOrCreate),
      .init(sessionExists: nil, tabsInDirectory: 1, isNewlyAdded: false, expected: .attachOrCreate),
      .init(sessionExists: nil, tabsInDirectory: 2, isNewlyAdded: false, expected: .attachOrCreate),
      .init(sessionExists: nil, tabsInDirectory: 5, isNewlyAdded: false, expected: .attachOrCreate),
    ] as [OnOpenCase]
  )
  func onOpen(testCase: OnOpenCase) {
    #expect(
      TerminalTabSessionRule.onOpen(
        sessionExists: testCase.sessionExists,
        tabsInDirectory: testCase.tabsInDirectory,
        isNewlyAdded: testCase.isNewlyAdded,
        isRestored: false
      ) == testCase.expected
    )
  }

  @Test(
    "復元時は新規追加と閉じる判定を優先しsessionの存在を確認できなければ作成を問う (設計書 §3.3)",
    arguments: [
      .init(sessionExists: true, tabsInDirectory: 1, isNewlyAdded: true, expected: .attachOrCreate),
      .init(sessionExists: true, tabsInDirectory: 2, isNewlyAdded: true, expected: .attachOrCreate),
      .init(
        sessionExists: false, tabsInDirectory: 1, isNewlyAdded: true, expected: .attachOrCreate),
      .init(
        sessionExists: false, tabsInDirectory: 2, isNewlyAdded: true, expected: .attachOrCreate),
      .init(sessionExists: nil, tabsInDirectory: 1, isNewlyAdded: true, expected: .attachOrCreate),
      .init(sessionExists: nil, tabsInDirectory: 2, isNewlyAdded: true, expected: .attachOrCreate),
      .init(
        sessionExists: true, tabsInDirectory: 1, isNewlyAdded: false, expected: .attachOrCreate),
      .init(
        sessionExists: true, tabsInDirectory: 2, isNewlyAdded: false, expected: .attachOrCreate),
      .init(sessionExists: false, tabsInDirectory: 1, isNewlyAdded: false, expected: .offerCreate),
      .init(sessionExists: false, tabsInDirectory: 2, isNewlyAdded: false, expected: .closeTab),
      .init(sessionExists: nil, tabsInDirectory: 1, isNewlyAdded: false, expected: .offerCreate),
      .init(sessionExists: nil, tabsInDirectory: 2, isNewlyAdded: false, expected: .offerCreate),
    ] as [OnOpenCase]
  )
  func onOpenRestored(testCase: OnOpenCase) {
    #expect(
      TerminalTabSessionRule.onOpen(
        sessionExists: testCase.sessionExists,
        tabsInDirectory: testCase.tabsInDirectory,
        isNewlyAdded: testCase.isNewlyAdded,
        isRestored: true
      ) == testCase.expected
    )
  }
}

import TerminalCore
import Testing

@Suite("タブ列の並びの規則 (設計書 §3.1)")
struct TerminalTabLayoutTests {
  private func identity(_ name: String) throws -> WorktreeIdentity {
    try #require(WorktreeIdentity(rawValue: "/repo/.git/worktrees/\(name)"))
  }

  private func key(_ identity: WorktreeIdentity, index: Int) throws -> TerminalSessionKey {
    try #require(TerminalSessionKey(identity: identity, index: index))
  }

  @Test("空のlayoutは各ディレクトリのprimaryを1枚ずつ返す")
  func emptyLayoutUsesPrimaryTabs() throws {
    let first = try identity("a")
    let second = try identity("b")
    let layout = TerminalTabLayout()

    #expect(layout.tabs(directories: [first, second]) == [.primary(first), .primary(second)])
    #expect(layout.tabs(in: first) == [.primary(first)])
    #expect(layout.tabs(in: second) == [.primary(second)])
    #expect(layout.tabs(directories: []).isEmpty)
  }

  @Test("追加タブは2から採番し同じディレクトリ内で昇順に並ぶ")
  func addedTabsFollowPrimaryInIndexOrder() throws {
    let first = try identity("a")
    let second = try identity("b")
    let firstExtra = try key(first, index: 2)
    let secondExtra = try key(first, index: 3)
    var layout = TerminalTabLayout()

    #expect(layout.addTab(in: first, existingSessionNames: []) == firstExtra)
    #expect(layout.addTab(in: first, existingSessionNames: []) == secondExtra)
    #expect(layout.tabs(in: first) == [.primary(first), firstExtra, secondExtra])
    #expect(
      layout.tabs(directories: [first, second])
        == [.primary(first), firstExtra, secondExtra, .primary(second)])
  }

  @Test("追加した順ではなくディレクトリごとにまとめる")
  func tabsAreGroupedRegardlessOfAdditionOrder() throws {
    let first = try identity("a")
    let second = try identity("b")
    let firstExtra = try key(first, index: 2)
    let secondExtra = try key(second, index: 2)
    var layout = TerminalTabLayout()

    #expect(layout.addTab(in: second, existingSessionNames: []) == secondExtra)
    #expect(layout.addTab(in: first, existingSessionNames: []) == firstExtra)
    #expect(
      layout.tabs(directories: [first, second])
        == [.primary(first), firstExtra, .primary(second), secondExtra])
  }

  @Test("既存sessionのindexが5なら6を追加し既存session自体はタブに足さない")
  func existingSessionDeterminesNextIndex() throws {
    let directory = try identity("a")
    let existing = TmuxSessionName(key: try key(directory, index: 5)).rawValue
    let added = try key(directory, index: 6)
    var layout = TerminalTabLayout()

    #expect(layout.addTab(in: directory, existingSessionNames: [existing]) == added)
    #expect(layout.tabs(in: directory) == [.primary(directory), added])
  }

  @Test(
    "layoutと既存sessionの両方の最大indexに1を足す",
    arguments: [(2, 6), (8, 9)]
  )
  func nextIndexUsesBothMaxima(existingIndex: Int, expectedIndex: Int) throws {
    let directory = try identity("a")
    let fifth = try key(directory, index: 5)
    let fourthName = TmuxSessionName(key: try key(directory, index: 4)).rawValue
    var layout = TerminalTabLayout()
    #expect(layout.addTab(in: directory, existingSessionNames: [fourthName]) == fifth)
    let existing = TmuxSessionName(key: try key(directory, index: existingIndex)).rawValue
    let expected = try key(directory, index: expectedIndex)

    #expect(layout.addTab(in: directory, existingSessionNames: [existing]) == expected)
    #expect(layout.tabs(in: directory) == [.primary(directory), fifth, expected])
  }

  @Test("他のidentityやawt以外のsession名は採番に影響しない")
  func foreignSessionNamesDoNotAffectIndex() throws {
    let directory = try identity("a")
    let foreign = try identity("b")
    let foreignName = TmuxSessionName(key: try key(foreign, index: 9999)).rawValue
    let added = try key(directory, index: 2)
    var layout = TerminalTabLayout()

    #expect(
      layout.addTab(in: directory, existingSessionNames: [foreignName, "shell", "unrelated-9999"])
        == added)
    #expect(layout.tabs(in: directory) == [.primary(directory), added])
  }

  @Test("途中の番号を外しても欠番は詰めない")
  func removedGapIsNotFilled() throws {
    let directory = try identity("a")
    let second = try key(directory, index: 2)
    let third = try key(directory, index: 3)
    let fourth = try key(directory, index: 4)
    var layout = TerminalTabLayout()
    #expect(layout.addTab(in: directory, existingSessionNames: []) == second)
    #expect(layout.addTab(in: directory, existingSessionNames: []) == third)
    layout.removeTab(second)

    #expect(layout.addTab(in: directory, existingSessionNames: []) == fourth)
    #expect(layout.tabs(in: directory) == [.primary(directory), third, fourth])
  }

  @Test("最大の番号のタブを外した後は、その番号を再び使う (設計書 §3.5 の最大 + 1)")
  func removedMaximumIsReusedWhenSessionIsGone() throws {
    let directory = try identity("a")
    let second = try key(directory, index: 2)
    let third = try key(directory, index: 3)
    var layout = TerminalTabLayout()
    #expect(layout.addTab(in: directory, existingSessionNames: []) == second)
    #expect(layout.addTab(in: directory, existingSessionNames: []) == third)
    layout.removeTab(third)

    // 閉じたタブの session は消えているので、existing にも現れない。
    let names = [
      TmuxSessionName(key: .primary(directory)).rawValue, TmuxSessionName(key: second).rawValue,
    ]
    #expect(layout.addTab(in: directory, existingSessionNames: names) == third)
  }

  @Test("existing に同じディレクトリの名前が複数あれば最大の次を使う")
  func multipleExistingNamesUseTheirMaximum() throws {
    let directory = try identity("a")
    let names = try [7, 1, 3].map { TmuxSessionName(key: try key(directory, index: $0)).rawValue }
    var layout = TerminalTabLayout()

    let expected = try key(directory, index: 8)
    #expect(layout.addTab(in: directory, existingSessionNames: names) == expected)
  }

  @Test("primary だけに戻った layout は既定と等しい")
  func layoutBackToPrimaryEqualsDefault() throws {
    let directory = try identity("a")
    var layout = TerminalTabLayout()
    let added = layout.addTab(in: directory, existingSessionNames: [])
    layout.removeTab(try #require(added))

    #expect(layout == TerminalTabLayout())
  }

  @Test("既存sessionに9999があれば追加できずlayoutは変わらない", arguments: [false, true])
  func existingMaximumRejectsAddition(hasExtraTab: Bool) throws {
    let directory = try identity("a")
    var layout = TerminalTabLayout()
    if hasExtraTab {
      #expect(
        layout.addTab(in: directory, existingSessionNames: []) == (try key(directory, index: 2)))
    }
    let before = layout
    let tabsBefore = layout.tabs(in: directory)
    let existing = TmuxSessionName(key: try key(directory, index: 9999)).rawValue

    #expect(layout.addTab(in: directory, existingSessionNames: [existing]) == nil)
    #expect(layout == before)
    #expect(layout.tabs(in: directory) == tabsBefore)
  }

  @Test("9998の次は9999を追加できlayout内が9999なら次を追加できない")
  func layoutMaximumRejectsAddition() throws {
    let directory = try identity("a")
    let existing = TmuxSessionName(key: try key(directory, index: 9998)).rawValue
    let last = try key(directory, index: 9999)
    var layout = TerminalTabLayout()

    #expect(layout.addTab(in: directory, existingSessionNames: [existing]) == last)
    #expect(layout.tabs(in: directory) == [.primary(directory), last])
    let before = layout

    #expect(layout.addTab(in: directory, existingSessionNames: []) == nil)
    #expect(layout == before)
    #expect(layout.tabs(in: directory) == [.primary(directory), last])
  }

  @Test("primaryを外すと追加タブだけ残り最後の1枚を外すとprimaryに戻る")
  func removingPrimaryAndLastTabRestoresDefault() throws {
    let directory = try identity("a")
    let second = try key(directory, index: 2)
    var layout = TerminalTabLayout()
    #expect(layout.addTab(in: directory, existingSessionNames: []) == second)

    layout.removeTab(.primary(directory))
    #expect(layout.tabs(in: directory) == [second])
    #expect(layout.tabs(directories: [directory]) == [second])

    layout.removeTab(second)
    #expect(layout.tabs(in: directory) == [.primary(directory)])
  }

  @Test("既定のprimaryだけを外してもprimaryの1枚に戻る")
  func removingDefaultPrimaryRestoresDefault() throws {
    let directory = try identity("a")
    var layout = TerminalTabLayout()

    layout.removeTab(.primary(directory))

    #expect(layout.tabs(in: directory) == [.primary(directory)])
  }

  @Test("layoutに無いindexやidentityの鍵を外しても変わらない")
  func removingUnknownKeysDoesNothing() throws {
    let directory = try identity("a")
    let foreign = try identity("b")
    var layout = TerminalTabLayout()
    #expect(
      layout.addTab(in: directory, existingSessionNames: []) == (try key(directory, index: 2)))
    let before = layout

    layout.removeTab(try key(directory, index: 3))
    layout.removeTab(try key(foreign, index: 2))

    #expect(layout == before)
    #expect(layout.tabs(in: directory) == [.primary(directory), try key(directory, index: 2)])
    #expect(layout.tabs(in: foreign) == [.primary(foreign)])
  }

  @Test("directoriesに無いidentityの追加タブは並ばず再び含めれば並ぶ")
  func omittedDirectoriesKeepTheirTabsWithoutDisplayingThem() throws {
    let first = try identity("a")
    let second = try identity("b")
    let extra = try key(second, index: 2)
    var layout = TerminalTabLayout()
    #expect(layout.addTab(in: second, existingSessionNames: []) == extra)

    #expect(layout.tabs(directories: [first]) == [.primary(first)])
    #expect(layout.tabs(directories: []).isEmpty)
    #expect(
      layout.tabs(directories: [first, second]) == [.primary(first), .primary(second), extra])
  }

  @Test("directoriesで重複するidentityは最初の位置に1回だけ並ぶ")
  func duplicateDirectoriesAppearOnce() throws {
    let first = try identity("a")
    let second = try identity("b")
    let extra = try key(first, index: 2)
    var layout = TerminalTabLayout()
    #expect(layout.addTab(in: first, existingSessionNames: []) == extra)

    #expect(
      layout.tabs(directories: [second, first, second, first])
        == [.primary(second), .primary(first), extra])
  }

  @Test("Project Rootを含めdirectoriesで渡した順にタブ群が並ぶ")
  func directoryOrderControlsGroupOrder() throws {
    let project = try #require(WorktreeIdentity(rawValue: "/repo/.git"))
    let worktree = try identity("a")
    let projectExtra = try key(project, index: 2)
    let worktreeExtra = try key(worktree, index: 2)
    var layout = TerminalTabLayout()
    #expect(layout.addTab(in: worktree, existingSessionNames: []) == worktreeExtra)
    #expect(layout.addTab(in: project, existingSessionNames: []) == projectExtra)

    #expect(
      layout.tabs(directories: [project, worktree])
        == [.primary(project), projectExtra, .primary(worktree), worktreeExtra])
    #expect(
      layout.tabs(directories: [worktree, project])
        == [.primary(worktree), worktreeExtra, .primary(project), projectExtra])
  }

  @Test("baseと連番のsessionからタブを復元する (設計書 §3.5)")
  func restoresPrimaryAndAdditionalTabs() throws {
    let directory = try identity("a")
    let second = try key(directory, index: 2)
    let third = try key(directory, index: 3)
    let names = [
      TmuxSessionName(identity: directory).rawValue,
      TmuxSessionName(key: second).rawValue,
      TmuxSessionName(key: third).rawValue,
    ]
    var layout = TerminalTabLayout()

    layout.restore(from: names, identities: [directory])

    #expect(layout.tabs(in: directory) == [.primary(directory), second, third])
  }

  @Test("baseが無いsession列の復元ではprimaryや欠番を補わない (設計書 §3.5)")
  func restoresOnlyExistingSessionTabs() throws {
    let directory = try identity("a")
    let second = try key(directory, index: 2)
    let fifth = try key(directory, index: 5)
    let names = [TmuxSessionName(key: second).rawValue, TmuxSessionName(key: fifth).rawValue]
    var layout = TerminalTabLayout()

    layout.restore(from: names, identities: [directory])

    #expect(layout.tabs(in: directory) == [second, fifth])
  }

  @Test("該当sessionが無ければ追加済みのタブを既定に戻す (設計書 §3.5)")
  func missingSessionsRestoreDefaultLayout() throws {
    let directory = try identity("a")
    let foreign = try identity("b")
    let names = [TmuxSessionName(identity: foreign).rawValue, "shell", "unrelated-2"]
    var layout = TerminalTabLayout()
    #expect(
      layout.addTab(in: directory, existingSessionNames: []) == (try key(directory, index: 2)))

    layout.restore(from: names, identities: [directory])

    #expect(layout.tabs(in: directory) == [.primary(directory)])
    #expect(layout == TerminalTabLayout())
  }

  @Test("baseだけを復元したlayoutは既定と等しい (設計書 §3.5)")
  func restoringPrimaryEqualsDefaultLayout() throws {
    let directory = try identity("a")
    var layout = TerminalTabLayout()

    layout.restore(from: [TmuxSessionName(identity: directory).rawValue], identities: [directory])

    #expect(layout.tabs(in: directory) == [.primary(directory)])
    #expect(layout == TerminalTabLayout())
  }

  @Test("複数identityを復元するとdirectoriesの順にタブ群が並ぶ (設計書 §3.5)")
  func restoresEachIdentityInDirectoryOrder() throws {
    let first = try identity("a")
    let second = try identity("b")
    let firstExtra = try key(first, index: 3)
    let secondExtra = try key(second, index: 2)
    let names = [
      TmuxSessionName(key: secondExtra).rawValue,
      TmuxSessionName(identity: first).rawValue,
      TmuxSessionName(key: firstExtra).rawValue,
    ]
    var layout = TerminalTabLayout()

    layout.restore(from: names, identities: [first, second])

    #expect(layout.tabs(in: first) == [.primary(first), firstExtra])
    #expect(layout.tabs(in: second) == [secondExtra])
    #expect(
      layout.tabs(directories: [first, second]) == [.primary(first), firstExtra, secondExtra])
  }

  @Test("baseだけの復元は追加済みのタブを置き換える (設計書 §3.5)")
  func restoringPrimaryReplacesAddedTabs() throws {
    let directory = try identity("a")
    var layout = TerminalTabLayout()
    #expect(
      layout.addTab(in: directory, existingSessionNames: []) == (try key(directory, index: 2)))

    layout.restore(from: [TmuxSessionName(identity: directory).rawValue], identities: [directory])

    #expect(layout.tabs(in: directory) == [.primary(directory)])
    #expect(layout == TerminalTabLayout())
  }

  @Test("復元対象に含まれないidentityの追加済みタブは残る (設計書 §3.5)")
  func restorationPreservesUnlistedIdentity() throws {
    let first = try identity("a")
    let second = try identity("b")
    let firstExtra = try key(first, index: 3)
    let secondExtra = try key(second, index: 2)
    let names = [
      TmuxSessionName(key: firstExtra).rawValue,
      TmuxSessionName(identity: second).rawValue,
    ]
    var layout = TerminalTabLayout()
    #expect(layout.addTab(in: second, existingSessionNames: []) == secondExtra)
    let secondTabsBefore = layout.tabs(in: second)

    layout.restore(from: names, identities: [first])

    #expect(layout.tabs(in: first) == [firstExtra])
    #expect(layout.tabs(in: second) == secondTabsBefore)
    #expect(layout.tabs(in: second) == [.primary(second), secondExtra])
  }

  @Test("復元後の追加タブは復元した最大indexの次になる (設計書 §3.5)")
  func additionAfterRestorationUsesRestoredMaximum() throws {
    let directory = try identity("a")
    let second = try key(directory, index: 2)
    let fifth = try key(directory, index: 5)
    let sixth = try key(directory, index: 6)
    let names = [TmuxSessionName(key: second).rawValue, TmuxSessionName(key: fifth).rawValue]
    var layout = TerminalTabLayout()
    layout.restore(from: names, identities: [directory])

    #expect(layout.addTab(in: directory, existingSessionNames: []) == sixth)
    #expect(layout.tabs(in: directory) == [second, fifth, sixth])
  }

  @Test("session名の入力順にかかわらずindexの昇順で復元する (設計書 §3.5)")
  func restorationSortsSessionIndices() throws {
    let directory = try identity("a")
    let second = try key(directory, index: 2)
    let third = try key(directory, index: 3)
    let names = [
      TmuxSessionName(key: third).rawValue,
      TmuxSessionName(identity: directory).rawValue,
      TmuxSessionName(key: second).rawValue,
    ]
    var layout = TerminalTabLayout()

    layout.restore(from: names, identities: [directory])

    #expect(layout.tabs(in: directory) == [.primary(directory), second, third])
  }

  @Test("layoutのコピーに追加しても元の値は変わらない")
  func copiesHaveIndependentState() throws {
    let directory = try identity("a")
    let original = TerminalTabLayout()
    var copy = original

    #expect(copy == original)
    #expect(copy.addTab(in: directory, existingSessionNames: []) == (try key(directory, index: 2)))
    #expect(copy != original)
    #expect(original.tabs(in: directory) == [.primary(directory)])
    #expect(copy.tabs(in: directory) == [.primary(directory), try key(directory, index: 2)])
  }

  @Test("別々に同じタブを追加したlayoutは等しい")
  func independentlyCreatedLayoutsAreEqual() throws {
    let directory = try identity("a")
    let extra = try key(directory, index: 2)
    var first = TerminalTabLayout()
    var second = TerminalTabLayout()

    #expect(first == second)
    #expect(first.addTab(in: directory, existingSessionNames: []) == extra)
    #expect(second.addTab(in: directory, existingSessionNames: []) == extra)
    #expect(first == second)
  }

  @Test("復元は既存のタブと併合せず、読んだ列で置き換える")
  func restoreReplacesExistingTabsWithReadIndices() throws {
    let directory = try identity("a")
    var layout = TerminalTabLayout()
    _ = layout.addTab(in: directory, existingSessionNames: [])
    _ = layout.addTab(in: directory, existingSessionNames: [])
    let fifth = try key(directory, index: 5)

    layout.restore(from: [TmuxSessionName(key: fifth).rawValue], identities: [directory])

    #expect(layout.tabs(in: directory) == [fifth])
  }
}

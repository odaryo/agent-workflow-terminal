import Foundation
import TerminalCore
import Testing

@Suite("全 Agent pane Overview の行と並び順 (設計書 §13)")
struct AgentPaneOverviewTests {
  private let base = ContinuousClock().now

  @Test("Project は入力 (登録) の順のまま並べ、Needs Attention があっても動かさない")
  func projectsKeepRegistrationOrder() throws {
    let quiet = try project(
      "/a/.git", tasks: [try task("/a/.git/worktrees/t", [pane("%1", .idle, 1)])])
    let urgent = try project(
      "/b/.git", tasks: [try task("/b/.git/worktrees/t", [pane("%2", .permission, 9)])])

    let overview = makeAgentPaneOverview([quiet, urgent])

    #expect(overview.map(\.project) == [quiet.project, urgent.project])
  }

  @Test("Project Root は Task と混ぜずに別枠へ置く")
  func projectRootIsSeparate() throws {
    let root = try task("/a", [pane("%9", .question, 9)])
    let input = try project(
      "/a/.git", root: root, tasks: [try task("/a/.git/worktrees/t", [pane("%1", .idle, 1)])])

    let overview = try #require(makeAgentPaneOverview([input]).first)

    #expect(overview.projectRoot?.worktree == root.worktree)
    #expect(overview.tasks.map(\.worktree) == [input.tasks[0].worktree])
  }

  @Test("Task は Needs Attention や最終更新にかかわらず入力順を保つ")
  func tasksKeepInputOrderRegardlessOfAttentionAndLastUpdate() throws {
    let old = try task("/a/.git/worktrees/old", [pane("%1", .working, 1)])
    let recent = try task("/a/.git/worktrees/recent", [pane("%2", .working, 8)])
    let attention = try task(
      "/a/.git/worktrees/attention", [pane("%3", .working, 9), pane("%4", .error, 2)])

    let overview = try #require(
      makeAgentPaneOverview([try project("/a/.git", tasks: [old, recent, attention])]).first)

    #expect(overview.tasks.map(\.worktree) == [old, recent, attention].map(\.worktree))
  }

  @Test("種別不明の Needs Attention があっても Task は入力順を保つ")
  func undeterminedAttentionDoesNotReorderTasks() throws {
    let plain = try task("/a/.git/worktrees/plain", [pane("%1", .working, 9)])
    let undetermined = try task(
      "/a/.git/worktrees/undetermined",
      [
        PaneDisplayState(
          paneID: PaneID(rawValue: "%2"), state: .unknown, category: .needsAttention,
          changedAt: at(1))
      ])

    let overview = try #require(
      makeAgentPaneOverview([try project("/a/.git", tasks: [plain, undetermined])]).first)

    #expect(overview.tasks.map(\.worktree) == [plain, undetermined].map(\.worktree))
  }

  @Test("Needs Attention を含む Task どうしも最終更新にかかわらず入力順を保つ")
  func attentionTasksKeepInputOrderRegardlessOfLastUpdate() throws {
    let older = try task("/a/.git/worktrees/older", [pane("%1", .question, 2)])
    let newer = try task("/a/.git/worktrees/newer", [pane("%2", .idle, 7), pane("%3", .error, 1)])

    let overview = try #require(
      makeAgentPaneOverview([try project("/a/.git", tasks: [older, newer])]).first)

    #expect(overview.tasks.map(\.worktree) == [older, newer].map(\.worktree))
  }

  @Test("最終更新が同じ Task は入力 (tab) の順を保つ")
  func tiesKeepTabOrder() throws {
    let first = try task("/a/.git/worktrees/first", [pane("%1", .working, 5)])
    let second = try task("/a/.git/worktrees/second", [pane("%2", .idle, 5)])

    let overview = try #require(
      makeAgentPaneOverview([try project("/a/.git", tasks: [first, second])]).first)

    #expect(overview.tasks.map(\.worktree) == [first, second].map(\.worktree))
  }

  @Test("Agent pane の有無にかかわらず Task は入力順を保つ")
  func tasksKeepInputOrderRegardlessOfAgentPanes() throws {
    let emptyA = try task("/a/.git/worktrees/emptyA", [])
    let busy = try task("/a/.git/worktrees/busy", [pane("%1", .idle, 1)])
    let emptyB = try task("/a/.git/worktrees/emptyB", [])

    let overview = try #require(
      makeAgentPaneOverview([try project("/a/.git", tasks: [emptyA, busy, emptyB])]).first)

    #expect(overview.tasks.map(\.worktree) == [emptyA, busy, emptyB].map(\.worktree))
  }

  @Test("Agent pane の無い Task と Project Root は「Agent pane なし」の行1つで示す")
  func emptyTaskHasSingleNoAgentRow() throws {
    let input = try project(
      "/a/.git", root: try task("/a", []), tasks: [try task("/a/.git/worktrees/empty", [])])

    let overview = try #require(makeAgentPaneOverview([input]).first)

    #expect(overview.projectRoot?.rows == [.noAgentPane])
    #expect(overview.tasks.first?.rows == [.noAgentPane])
  }

  @Test("Task 内の pane は Needs Attention や最終更新にかかわらず入力順を保つ")
  func panesWithinTaskKeepInputOrder() throws {
    let input = try task(
      "/a/.git/worktrees/t",
      [
        pane("%1", .working, 3),
        pane("%2", .question, 1),
        pane("%3", .idle, 6),
        pane("%4", .permission, 4),
        pane("%5", .completed, 6),
      ])

    let overview = try #require(
      makeAgentPaneOverview([try project("/a/.git", tasks: [input])]).first)

    #expect(paneIDs(overview.tasks[0]) == ["%1", "%2", "%3", "%4", "%5"])
  }

  @Test("行にするのは状態のある (Agent と判定された) pane だけで、概要しか無い pane は出さない")
  func onlyAgentPanesBecomeRows() throws {
    var input = try task("/a/.git/worktrees/t", [pane("%1", .working, 1)])
    input.details = [
      PaneID(rawValue: "%1"): OverviewPaneDetail(purpose: "実装"),
      PaneID(rawValue: "%7"): OverviewPaneDetail(purpose: "zsh の pane"),
    ]

    let overview = try #require(
      makeAgentPaneOverview([try project("/a/.git", tasks: [input])]).first)

    #expect(paneIDs(overview.tasks[0]) == ["%1"])
  }

  @Test(
    "pane title は接頭辞以外の内容と途中の空白を保ち、前後の空白と改行を除く (設計書 §12.7)",
    arguments: [
      ("\n title \n", "title"),
      ("title\r", "title"),
      ("作業  の確認", "作業  の確認"),
    ])
  func displayTitlePreservesNonPrefixContent(raw: String, expected: String) {
    #expect(OverviewPaneDetail.displayTitle(fromPaneTitle: raw) == expected)
  }

  @Test(
    "pane title の先頭の So 記号の Character 列と直後の空白列を1回だけ除く (設計書 §12.7)",
    arguments: [
      ("✳ 進捗の確認", "進捗の確認"),
      ("✳ 進捗の検索", "進捗の検索"),
      ("  ✳ 作業  ", "作業"),
      ("✳ 作業  の確認", "作業  の確認"),
      ("✳  作業  の確認", "作業  の確認"),
      ("✳️ 作業", "作業"),
      ("⠋ repo", "repo"),
      ("✳✳ 作業", "作業"),
      ("✳ ✳ 作業", "✳ 作業"),
      ("✳\u{3000}作業", "作業"),
    ])
  func displayTitleStripsLeadingSymbolPrefixOnce(raw: String, expected: String) {
    #expect(OverviewPaneDetail.displayTitle(fromPaneTitle: raw) == expected)
  }

  @Test(
    "pane title の空白が続かない記号・So 以外の記号・途中の記号は保つ (設計書 §12.7)",
    arguments: [
      ("★重要", "★重要"),
      ("✳", "✳"),
      ("~/w/h/ktc-platform", "~/w/h/ktc-platform"),
      ("$ make", "$ make"),
      ("^ up", "^ up"),
      ("a ✳ b", "a ✳ b"),
    ])
  func displayTitlePreservesContentWithoutSymbolPrefix(raw: String, expected: String) {
    #expect(OverviewPaneDetail.displayTitle(fromPaneTitle: raw) == expected)
  }

  @Test(
    "pane title は接頭辞内の制御文字・行区切りも拒否し、接頭辞除去後に書式文字と空白だけなら表示しない (設計書 §12.7)",
    arguments: [
      "✳ \u{FEFF}", "✳ a\nb", "✳\n作業", "✳\r\n作業", "✳\t作業", "✳\u{85}作業",
      "✳\u{2028}作業", "✳\u{2029}作業", "✳ \n作業",
    ])
  func displayTitleValidatesBeforeAndAfterStrippingSymbolPrefix(raw: String) {
    #expect(OverviewPaneDetail.displayTitle(fromPaneTitle: raw) == nil)
  }

  @Test("空か空白と改行だけの pane title は表示しない (設計書 §12.7)", arguments: ["", "   ", "\n"])
  func emptyDisplayTitleIsNil(raw: String) {
    #expect(OverviewPaneDetail.displayTitle(fromPaneTitle: raw) == nil)
  }

  @Test(
    "途中に制御文字か行区切りを含む pane title は表示しない (設計書 §12.7)",
    arguments: [
      "a\rb", "a\nb", "a\tb", "a\u{0}b", "a\u{1B}b", "a\u{7F}b", "a\u{85}b",
      "a\u{2028}b", "a\u{2029}b",
    ])
  func multilineOrControlDisplayTitleIsNil(raw: String) {
    #expect(OverviewPaneDetail.displayTitle(fromPaneTitle: raw) == nil)
  }

  @Test(
    "末尾の NEL・行区切り・TAB は拒否判定の前に除いて表示する (設計書 §12.7)",
    arguments: [
      ("title\u{0085}", "title"),
      ("title\u{2028}", "title"),
      ("title\t", "title"),
    ])
  func displayTitleTrimsTrailingWhitespaceBeforeValidation(raw: String, expected: String) {
    #expect(OverviewPaneDetail.displayTitle(fromPaneTitle: raw) == expected)
  }

  @Test(
    "末尾でも trim されない ESC・DEL を含む pane title は表示しない (設計書 §12.7)",
    arguments: ["title\u{1B}", "title\u{7F}"])
  func displayTitleWithTrailingNonWhitespaceControlIsNil(raw: String) {
    #expect(OverviewPaneDetail.displayTitle(fromPaneTitle: raw) == nil)
  }

  @Test(
    "default-ignorable な書式文字と空白だけの pane title は表示しない (設計書 §12.7)",
    arguments: ["\u{FEFF}", "\u{200B}", " \u{FEFF} ", "\u{FEFF}\u{200B}", "\u{FEFF} \u{FEFF}"])
  func formatOnlyDisplayTitleIsNil(raw: String) {
    #expect(OverviewPaneDetail.displayTitle(fromPaneTitle: raw) == nil)
  }

  @Test(
    "default-ignorable と空白だけの pane title は表示しない (設計書 §12.7)",
    arguments: [
      "\u{3164}", "\u{115F}\u{1160}", "\u{FFA0}", "\u{FE0F}", "\u{E0100}", "\u{034F}",
      " \u{3164} ",
    ])
  func defaultIgnorableOnlyDisplayTitleIsNil(raw: String) {
    #expect(OverviewPaneDetail.displayTitle(fromPaneTitle: raw) == nil)
  }

  @Test(
    "見える字形を持つ Cf と空白に続く結合文字の pane title は trim 後の値を表示する (設計書 §12.7)",
    arguments: [("\u{6DD}", "\u{6DD}"), (" \u{301}", "\u{301}")])
  func displayTitlePreservesVisibleFormatOrCombiningCharacter(raw: String, expected: String) {
    #expect(OverviewPaneDetail.displayTitle(fromPaneTitle: raw) == expected)
  }

  @Test("U+2800 は見えない scalar の対象外として pane title にそのまま表示する (設計書 §12.7)")
  func displayTitlePreservesBraillePatternBlank() {
    #expect(OverviewPaneDetail.displayTitle(fromPaneTitle: "\u{2800}") == "\u{2800}")
  }

  @Test(
    "見える文字と default-ignorable が混ざった pane title はそのまま表示する (設計書 §12.7)",
    arguments: ["a\u{FE0F}", "\u{3164}abc"])
  func displayTitlePreservesDefaultIgnorablesWithVisibleContent(raw: String) {
    #expect(OverviewPaneDetail.displayTitle(fromPaneTitle: raw) == raw)
  }

  @Test(
    "見える文字と書式文字 (Cf) が混ざった pane title はそのまま表示する (設計書 §12.7)",
    arguments: [
      ("\u{202E}abc", "\u{202E}abc"),
      ("a\u{200B}b", "a\u{200B}b"),
    ])
  func displayTitlePreservesFormatCharactersWithVisibleContent(raw: String, expected: String) {
    #expect(OverviewPaneDetail.displayTitle(fromPaneTitle: raw) == expected)
  }

  @Test("概要の title は既定で nil になり、等価性と Hashable に含まれる (設計書 §12.7)")
  func titleParticipatesInEqualityAndHashing() {
    let empty = OverviewPaneDetail()
    let titled = OverviewPaneDetail(title: "x")
    var changed = titled
    changed.title = "y"

    #expect(empty.title == nil)
    #expect(titled.title == "x")
    #expect(titled != empty)
    #expect(changed != titled)
    #expect(titled == OverviewPaneDetail(title: "x"))
    #expect(Set([empty, titled, changed, OverviewPaneDetail(title: "x")]).count == 3)
  }

  @Test("概要と位置と title を行へ渡し、概要がまだ無い pane は空の概要になる (設計書 §12.7 / §13)")
  func detailsArePassedThrough() throws {
    let detail = OverviewPaneDetail(
      location: PaneLocation(windowIndex: 1, paneIndex: 2), purpose: "目的", status: "実装中",
      isTaskCompleted: true, title: "✳ 進捗の確認")
    var input = try task("/a/.git/worktrees/t", [pane("%1", .working, 2), pane("%2", .idle, 1)])
    input.details = [PaneID(rawValue: "%1"): detail]

    let overview = try #require(
      makeAgentPaneOverview([try project("/a/.git", tasks: [input])]).first)

    let panes = overview.tasks[0].rows.compactMap(\.pane)
    #expect(panes.first?.detail == detail)
    #expect(panes.first?.detail.title == "✳ 進捗の確認")
    #expect(panes.last?.detail == OverviewPaneDetail())
    #expect(panes.last?.detail.title == nil)
  }

  @Test("メイン pane に登録された pane だけに印を付ける")
  func marksRegisteredMainPane() throws {
    var input = try task("/a/.git/worktrees/t", [pane("%1", .working, 2), pane("%2", .idle, 1)])
    input.mainPane = PaneID(rawValue: "%2")

    let overview = try #require(
      makeAgentPaneOverview([try project("/a/.git", tasks: [input])]).first)

    let panes = overview.tasks[0].rows.compactMap(\.pane)
    #expect(panes.map(\.isMain) == [false, true])
  }

  @Test("worktree から作った入力は番号 1 の session を指す")
  func worktreeInputIsPrimarySession() throws {
    let worktree = try #require(WorktreeIdentity(rawValue: "/a/.git/worktrees/t"))

    let input = OverviewWorktreeInput(worktree: worktree, paneStates: [])

    #expect(input.session == .primary(worktree))
    #expect(input.worktree == worktree)
  }

  @Test("session から作った入力の worktree はその session の worktree")
  func sessionInputHasSessionWorktree() throws {
    let key = try session("/a/.git/worktrees/t", 2)

    let input = OverviewWorktreeInput(session: key, paneStates: [])

    #expect(input.session == key)
    #expect(input.worktree == key.identity)
  }

  @Test("Project Root の session は入力 (番号) の順に並べ、Needs Attention があっても動かさない (設計書 §12.2)")
  func projectRootSessionsKeepInputOrder() throws {
    let first = try sessionInput(session("/a", 1), [pane("%1", .idle, 1)])
    let second = try sessionInput(session("/a", 2), [pane("%2", .question, 9)])
    let input = OverviewProjectInput(
      project: try #require(WorktreeIdentity(rawValue: "/a/.git")),
      projectRootSessions: [first, second], tasks: [])

    let overview = try #require(makeAgentPaneOverview([input]).first)

    #expect(overview.projectRootSessions.map(\.session) == [first.session, second.session])
    #expect(overview.projectRoot?.session == first.session)
    #expect(overview.projectRoot == overview.projectRootSessions.first)
  }

  @Test("Project Root の session が無ければ projectRoot は nil")
  func noProjectRootSessionsHasNoProjectRoot() throws {
    let input = OverviewProjectInput(
      project: try #require(WorktreeIdentity(rawValue: "/a/.git")), projectRootSessions: [],
      tasks: [])

    let overview = try #require(makeAgentPaneOverview([input]).first)

    #expect(overview.projectRootSessions.isEmpty)
    #expect(overview.projectRoot == nil)
  }

  @Test("projectRoot から作った入力は、その1つだけを Project Root の session に持つ")
  func projectRootInputIsSingleSession() throws {
    let root = try task("/a", [pane("%9", .idle, 1)])

    let withRoot = try project("/a/.git", root: root, tasks: [])
    let withoutRoot = try project("/a/.git", tasks: [])

    #expect(withRoot.projectRootSessions.map(\.session) == [root.session])
    #expect(withoutRoot.projectRootSessions.isEmpty)
    let overview = try #require(makeAgentPaneOverview([withRoot]).first)
    #expect(overview.projectRootSessions.map(\.session) == [.primary(root.worktree)])
    #expect(overview.projectRoot?.session == .primary(root.worktree))
  }

  @Test("同じ worktree の2つの session は束ねず、入力順で別々に並べる (設計書 §12.2 / §13)")
  func sessionsOfOneWorktreeAreSeparateTasks() throws {
    let first = try sessionInput(session("/a/.git/worktrees/t", 1), [pane("%1", .working, 3)])
    let other = try sessionInput(session("/a/.git/worktrees/u", 1), [pane("%2", .working, 5)])
    let second = try sessionInput(session("/a/.git/worktrees/t", 2), [pane("%3", .question, 1)])

    let overview = try #require(
      makeAgentPaneOverview([try project("/a/.git", tasks: [first, other, second])]).first)

    #expect(overview.tasks.map(\.session) == [first, other, second].map(\.session))
    #expect(overview.tasks.map(\.worktree) == [first, other, second].map(\.worktree))
    #expect(overview.tasks.map(paneIDs) == [["%1"], ["%2"], ["%3"]])
  }

  @Test("出力の session は入力の session と一致する")
  func outputCarriesInputSession() throws {
    let root = try sessionInput(session("/a", 3), [])
    let task = try sessionInput(session("/a/.git/worktrees/t", 2), [pane("%1", .idle, 1)])
    let input = OverviewProjectInput(
      project: try #require(WorktreeIdentity(rawValue: "/a/.git")),
      projectRootSessions: [root], tasks: [task])

    let overview = try #require(makeAgentPaneOverview([input]).first)

    #expect(overview.projectRootSessions.map(\.session) == [root.session])
    #expect(overview.projectRootSessions.map(\.worktree) == [root.worktree])
    #expect(overview.tasks.map(\.session) == [task.session])
    #expect(overview.tasks.map(\.worktree) == [task.worktree])
  }

  private func session(_ path: String, _ index: Int) throws -> TerminalSessionKey {
    let identity = try #require(WorktreeIdentity(rawValue: path))
    return try #require(TerminalSessionKey(identity: identity, index: index))
  }

  private func sessionInput(
    _ key: TerminalSessionKey, _ panes: [PaneDisplayState]
  ) -> OverviewWorktreeInput {
    OverviewWorktreeInput(session: key, paneStates: panes)
  }

  private func at(_ seconds: Int) -> ContinuousClock.Instant {
    base.advanced(by: .seconds(seconds))
  }

  private func pane(_ id: String, _ state: AgentState, _ seconds: Int) -> PaneDisplayState {
    PaneDisplayState(
      paneID: PaneID(rawValue: id), state: state, category: state.worktreeCategory,
      changedAt: at(seconds))
  }

  private func task(_ path: String, _ panes: [PaneDisplayState]) throws -> OverviewWorktreeInput {
    OverviewWorktreeInput(
      worktree: try #require(WorktreeIdentity(rawValue: path)), paneStates: panes)
  }

  private func project(
    _ path: String, root: OverviewWorktreeInput? = nil, tasks: [OverviewWorktreeInput]
  ) throws -> OverviewProjectInput {
    OverviewProjectInput(
      project: try #require(WorktreeIdentity(rawValue: path)), projectRoot: root, tasks: tasks)
  }

  private func paneIDs(_ worktree: OverviewWorktree) -> [String] {
    worktree.rows.compactMap(\.pane).map(\.paneID.rawValue)
  }
}

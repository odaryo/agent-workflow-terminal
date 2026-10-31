import TerminalCore
import Testing

@Suite("登録解除で削除するtmux sessionの導出 (設計書 §16.1 / Issue #406)")
struct ProjectSessionCleanupTests {

  // MARK: - Helpers

  private func identity(_ path: String) throws -> WorktreeIdentity {
    try #require(WorktreeIdentity(rawValue: path))
  }

  private func sessionName(_ path: String) throws -> TmuxSessionName {
    TmuxSessionName(identity: try identity(path))
  }

  private func task(_ path: String) throws -> PersistedTaskWorktree {
    PersistedTaskWorktree(
      identity: try identity(path),
      worktreePath: "/wt/\(path.split(separator: "/").last ?? "")",
      branch: nil,
      activation: .inactive
    )
  }

  private func saved(
    projectRoot: String?,
    tasks: [String]
  ) throws -> PersistedWorktreeInventory {
    PersistedWorktreeInventory(
      projectRoot: try projectRoot.map {
        PersistedProjectRootWorktree(identity: try identity($0), worktreePath: "/repo", branch: nil)
      },
      taskWorktrees: try tasks.map(task)
    )
  }

  private static let commonDirectory = "/repo/.git"
  private static let alpha = "/repo/.git/worktrees/alpha"
  private static let beta = "/repo/.git/worktrees/beta"
  private static let gamma = "/repo/.git/worktrees/gamma"

  // MARK: - 順序と重複

  @Test("Project Root → 保存のtask (保存順) → 観測 (渡された順) の順に並ぶ")
  func candidatesFollowSourceOrder() throws {
    let delta = "/repo/.git/worktrees/delta"
    let names = [
      try sessionName(Self.commonDirectory),
      try sessionName(Self.beta),
      try sessionName(Self.alpha),
      try sessionName(delta),
      try sessionName(Self.gamma),
    ]

    let result = ProjectSessionCleanup.sessions(
      projectCommonDirectory: try identity(Self.commonDirectory),
      saved: try saved(projectRoot: Self.commonDirectory, tasks: [Self.beta, Self.alpha]),
      observed: [try identity(delta), try identity(Self.gamma)],
      existingSessionNames: names.reversed().map(\.rawValue)
    )

    #expect(result == names)
  }

  // MARK: - この Project のものだけ

  /// 保存ファイルや観測に別 Project の安定 ID が紛れても、その Project の session を消さない。
  /// `<common>/worktrees/` の接頭辞は文字列ではなく UTF-8 バイト列で照合するので、正準等価な
  /// NFD 表記の Project も別物として扱う。
  @Test(
    "別Projectの安定IDは、そのsessionが実在しても返さない",
    arguments: [
      "/elsewhere/.git",
      "/elsewhere/.git/worktrees/alpha",
      "/repo/.gitx/worktrees/alpha",
      "/repo/.gitworktrees/alpha",
      "/repo/.git/worktreesalpha",
      "/repo/.git/modules/sub",
      "/repo",
      "/repo/.git/worktrees",
    ]
  )
  func identitiesOfOtherProjectsAreExcluded(foreign: String) throws {
    let foreignName = try sessionName(foreign)
    let root = try sessionName(Self.commonDirectory)
    try #require(foreignName != root)

    let result = ProjectSessionCleanup.sessions(
      projectCommonDirectory: try identity(Self.commonDirectory),
      saved: try saved(projectRoot: foreign, tasks: [foreign]),
      observed: [try identity(foreign)],
      existingSessionNames: [root.rawValue, foreignName.rawValue]
    )

    #expect(result == [root])
  }

  @Test("正準等価でもバイト列が違うcommon dir配下のworktreeは返さない")
  func canonicallyEquivalentButByteDifferentIsExcluded() throws {
    let nfcCommon = "/caf\u{00E9}/.git"
    let nfdTask = "/cafe\u{0301}/.git/worktrees/alpha"
    let nfcTask = "/caf\u{00E9}/.git/worktrees/beta"
    try #require(nfdTask.hasPrefix(nfcCommon + "/worktrees/"))
    let names = try [nfcCommon, nfdTask, nfcTask].map(sessionName)

    let result = ProjectSessionCleanup.sessions(
      projectCommonDirectory: try identity(nfcCommon),
      saved: try saved(projectRoot: nil, tasks: [nfdTask, nfcTask]),
      observed: [],
      existingSessionNames: names.map(\.rawValue)
    )

    #expect(result == [try sessionName(nfcCommon), try sessionName(nfcTask)])
  }

  @Test("同じ名前になる候補は最初の1件だけを残す")
  func duplicatesKeepFirstOccurrence() throws {
    let result = ProjectSessionCleanup.sessions(
      projectCommonDirectory: try identity(Self.commonDirectory),
      saved: try saved(projectRoot: Self.commonDirectory, tasks: [Self.alpha, Self.beta]),
      observed: [try identity(Self.beta), try identity(Self.alpha), try identity(Self.gamma)],
      existingSessionNames: try [Self.commonDirectory, Self.alpha, Self.beta, Self.gamma].map {
        try sessionName($0).rawValue
      }
    )

    #expect(
      result == [
        try sessionName(Self.commonDirectory),
        try sessionName(Self.alpha),
        try sessionName(Self.beta),
        try sessionName(Self.gamma),
      ])
  }

  @Test("存在するsessionの一覧に同じ名前が重なっていても1件しか返さない")
  func duplicatedExistingNamesDoNotDuplicateResult() throws {
    let root = try sessionName(Self.commonDirectory)

    let result = ProjectSessionCleanup.sessions(
      projectCommonDirectory: try identity(Self.commonDirectory),
      saved: nil,
      observed: [],
      existingSessionNames: [root.rawValue, root.rawValue]
    )

    #expect(result == [root])
  }

  // MARK: - 実在するものだけ

  @Test("存在しないsessionは返さない")
  func absentSessionsAreExcluded() throws {
    let result = ProjectSessionCleanup.sessions(
      projectCommonDirectory: try identity(Self.commonDirectory),
      saved: try saved(projectRoot: Self.commonDirectory, tasks: [Self.alpha, Self.beta]),
      observed: [try identity(Self.gamma)],
      existingSessionNames: [try sessionName(Self.beta).rawValue, "unrelated"]
    )

    #expect(result == [try sessionName(Self.beta)])
  }

  @Test("接頭辞やslugが同じでも導出した名前と完全一致しないsessionは返さない")
  func prefixOrSlugMatchIsNotEnough() throws {
    let root = try sessionName(Self.commonDirectory).rawValue
    let alpha = try sessionName(Self.alpha).rawValue
    let lookalikes = [
      "awt-repo-00000000",
      "awt-alpha-00000000",
      String(root.dropLast()),
      root + "x",
      " " + alpha,
      alpha.uppercased(),
      "awt-",
    ]
    try #require(!lookalikes.contains(root))
    try #require(!lookalikes.contains(alpha))

    let result = ProjectSessionCleanup.sessions(
      projectCommonDirectory: try identity(Self.commonDirectory),
      saved: try saved(projectRoot: nil, tasks: [Self.alpha]),
      observed: [],
      existingSessionNames: lookalikes
    )

    #expect(result.isEmpty)
  }

  // MARK: - 手がかりが欠けている場合

  @Test("保存が無くても、Project Rootと観測からsessionを導出する")
  func worksWithoutSavedInventory() throws {
    let result = ProjectSessionCleanup.sessions(
      projectCommonDirectory: try identity(Self.commonDirectory),
      saved: nil,
      observed: [try identity(Self.alpha)],
      existingSessionNames: try [Self.alpha, Self.commonDirectory].map {
        try sessionName($0).rawValue
      }
    )

    #expect(result == [try sessionName(Self.commonDirectory), try sessionName(Self.alpha)])
  }

  @Test("到達不能で観測が空でも、保存からsessionを導出する")
  func worksWithoutObservation() throws {
    let result = ProjectSessionCleanup.sessions(
      projectCommonDirectory: try identity(Self.commonDirectory),
      saved: try saved(projectRoot: Self.commonDirectory, tasks: [Self.alpha]),
      observed: [],
      existingSessionNames: try [Self.alpha, Self.commonDirectory].map {
        try sessionName($0).rawValue
      }
    )

    #expect(result == [try sessionName(Self.commonDirectory), try sessionName(Self.alpha)])
  }

  @Test("保存も観測も無ければ、Project Rootのsessionだけを導出する")
  func onlyProjectRootWhenNothingElseIsKnown() throws {
    let result = ProjectSessionCleanup.sessions(
      projectCommonDirectory: try identity(Self.commonDirectory),
      saved: nil,
      observed: [],
      existingSessionNames: try [Self.commonDirectory, Self.alpha].map {
        try sessionName($0).rawValue
      }
    )

    #expect(result == [try sessionName(Self.commonDirectory)])
  }

  @Test("存在するsessionが1つも無ければ空を返す")
  func emptyWhenNoSessionExists() throws {
    let result = ProjectSessionCleanup.sessions(
      projectCommonDirectory: try identity(Self.commonDirectory),
      saved: try saved(projectRoot: Self.commonDirectory, tasks: [Self.alpha]),
      observed: [try identity(Self.beta)],
      existingSessionNames: []
    )

    #expect(result.isEmpty)
  }

  @Test("保存・観測・存在するsessionのすべてが空なら空を返す")
  func emptyWhenEverythingIsEmpty() throws {
    let result = ProjectSessionCleanup.sessions(
      projectCommonDirectory: try identity(Self.commonDirectory),
      saved: try saved(projectRoot: nil, tasks: []),
      observed: [],
      existingSessionNames: []
    )

    #expect(result.isEmpty)
  }
}

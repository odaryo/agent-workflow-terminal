import TerminalCore
import Testing

@Suite("File Browser の Git 状態重ね合わせ (設計書 §7.1)")
struct WorktreeFileGitStateTests {
  private func path(_ value: String) throws -> WorktreeRelativePath {
    try #require(WorktreeRelativePath(value))
  }

  @Test("一致しないパスは tracked かつ変更なし")
  func unmatchedPathIsClean() throws {
    let overlay = WorktreeFileGitStateOverlay(entries: [])
    #expect(overlay.state(for: try path("Sources/main.swift")) == .tracked(.unchanged))
  }

  @Test("変更と unmerged は完全一致だけで変更種別を返す")
  func exactChangedEntries() throws {
    let renamed = try path("new.swift")
    let overlay = WorktreeFileGitStateOverlay(entries: [
      .changed(path: try path("modified.swift"), change: .modified),
      .changed(path: try path("added.swift"), change: .added),
      .changed(path: try path("deleted.swift"), change: .deleted),
      .changed(path: renamed, change: .renamed),
      .unmerged(path: try path("conflict.swift")),
    ])

    #expect(overlay.state(for: try path("modified.swift")) == .tracked(.modified))
    #expect(overlay.state(for: try path("added.swift")) == .tracked(.added))
    #expect(overlay.state(for: try path("deleted.swift")) == .tracked(.deleted))
    #expect(overlay.state(for: renamed) == .tracked(.renamed))
    #expect(overlay.state(for: try path("conflict.swift")) == .tracked(.unmerged))
    #expect(overlay.state(for: try path("old.swift")) == .tracked(.unchanged))
  }

  @Test("ディレクトリ scope は自身と配下だけに一致する")
  func directoryScopeMatchesAtComponentBoundary() throws {
    let overlay = WorktreeFileGitStateOverlay(entries: [
      .untracked(path: try path("foo"), scope: .directory)
    ])

    #expect(overlay.state(for: try path("foo")) == .untracked)
    #expect(overlay.state(for: try path("foo/bar")) == .untracked)
    #expect(overlay.state(for: try path("foobar")) == .tracked(.unchanged))
  }

  @Test("完全一致はディレクトリ scope より優先する")
  func exactChangeOverridesDirectoryScope() throws {
    let overlay = WorktreeFileGitStateOverlay(entries: [
      .ignored(path: try path("build"), scope: .directory),
      .changed(path: try path("build/kept.swift"), change: .modified),
      .unmerged(path: try path("build/conflict.swift")),
    ])

    #expect(overlay.state(for: try path("build/kept.swift")) == .tracked(.modified))
    #expect(overlay.state(for: try path("build/conflict.swift")) == .tracked(.unmerged))
  }

  @Test("より深いディレクトリ scope を優先する")
  func deeperDirectoryScopeWins() throws {
    let overlay = WorktreeFileGitStateOverlay(entries: [
      .ignored(path: try path("build"), scope: .directory),
      .untracked(path: try path("build/generated"), scope: .directory),
    ])

    #expect(overlay.state(for: try path("build/other")) == .ignored)
    #expect(overlay.state(for: try path("build/generated/file")) == .untracked)
  }

  @Test("同じ深さでは ignored を優先する")
  func ignoredWinsEqualDepthTie() throws {
    let prefix = try path("build")
    let overlay = WorktreeFileGitStateOverlay(entries: [
      .untracked(path: prefix, scope: .directory),
      .ignored(path: prefix, scope: .directory),
    ])

    #expect(overlay.state(for: try path("build/file")) == .ignored)
  }

  @Test("完全一致 scope は配下へ波及しない")
  func exactScopeDoesNotMatchDescendants() throws {
    let overlay = WorktreeFileGitStateOverlay(entries: [
      .untracked(path: try path("loose"), scope: .exact)
    ])

    #expect(overlay.state(for: try path("loose")) == .untracked)
    #expect(overlay.state(for: try path("loose/child")) == .tracked(.unchanged))
  }

  @Test("ディレクトリに配下の状態を集約しない")
  func doesNotAggregateDescendantChanges() throws {
    let overlay = WorktreeFileGitStateOverlay(entries: [
      .changed(path: try path("Sources/main.swift"), change: .modified)
    ])

    #expect(overlay.state(for: try path("Sources")) == .tracked(.unchanged))
  }

  @Test(
    "正規化されていない相対パスを拒否する",
    arguments: ["", "/foo", "./foo", "foo/", "foo//bar", "foo/./bar", "foo/../bar"]
  )
  func rejectsNonCanonicalPaths(_ value: String) {
    #expect(WorktreeRelativePath(value) == nil)
  }
}

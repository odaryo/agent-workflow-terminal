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
    #expect(
      overlay.state(for: try path("Sources/main.swift"), kind: .file)
        == .tracked(.unchanged))
    #expect(overlay.state(for: try path("Sources"), kind: .directory) == nil)
  }

  @Test("変更状態は index と worktree の2軸を損失なく返す")
  func exactChangedEntries() throws {
    let renamed = try path("new.swift")
    let overlay = WorktreeFileGitStateOverlay(entries: [
      .changed(path: try path("type.swift"), indexStatus: .unchanged, worktreeStatus: .typeChanged),
      .changed(path: try path("added.swift"), indexStatus: .added, worktreeStatus: .deleted),
      .changed(path: renamed, indexStatus: .renamed, worktreeStatus: .unchanged),
      .changed(path: try path("copy.swift"), indexStatus: .copied, worktreeStatus: .unchanged),
      .unmerged(
        path: try path("conflict.swift"), indexStatus: .unmerged, worktreeStatus: .modified),
    ])

    #expect(
      overlay.state(for: try path("type.swift"), kind: .file)
        == .tracked(.init(index: .unchanged, worktree: .typeChanged)))
    #expect(
      overlay.state(for: try path("added.swift"), kind: .file)
        == .tracked(.init(index: .added, worktree: .deleted)))
    #expect(
      overlay.state(for: renamed, kind: .file)
        == .tracked(.init(index: .renamed, worktree: .unchanged)))
    #expect(
      overlay.state(for: try path("copy.swift"), kind: .file)
        == .tracked(.init(index: .copied, worktree: .unchanged)))
    #expect(
      overlay.state(for: try path("conflict.swift"), kind: .file)
        == .tracked(.init(index: .unmerged, worktree: .modified)))
    #expect(overlay.state(for: try path("old.swift"), kind: .file) == .tracked(.unchanged))
  }

  @Test("badge は worktree 側を優先し、unchanged なら index 側を使う")
  func choosesDisplayedStatus() {
    #expect(
      WorktreeTrackedFileStatus(index: .added, worktree: .deleted).displayedStatus == .deleted)
    #expect(
      WorktreeTrackedFileStatus(index: .renamed, worktree: .unchanged).displayedStatus == .renamed)
  }

  @Test("ディレクトリ scope は自身と配下だけに一致する")
  func directoryScopeMatchesAtComponentBoundary() throws {
    let overlay = WorktreeFileGitStateOverlay(entries: [
      .untracked(path: try path("foo"), scope: .directory)
    ])

    #expect(overlay.state(for: try path("foo"), kind: .directory) == .untracked)
    #expect(overlay.state(for: try path("foo/bar"), kind: .file) == .untracked)
    #expect(overlay.state(for: try path("foobar"), kind: .file) == .tracked(.unchanged))
  }

  @Test("完全一致はディレクトリ scope より優先する")
  func exactChangeOverridesDirectoryScope() throws {
    let overlay = WorktreeFileGitStateOverlay(entries: [
      .ignored(path: try path("build"), scope: .directory),
      .changed(
        path: try path("build/kept.swift"), indexStatus: .modified, worktreeStatus: .unchanged),
      .unmerged(
        path: try path("build/conflict.swift"), indexStatus: .unmerged, worktreeStatus: .unmerged),
    ])

    #expect(
      overlay.state(for: try path("build/kept.swift"), kind: .file)?.displayedStatus == .modified)
    #expect(
      overlay.state(for: try path("build/conflict.swift"), kind: .file)?.displayedStatus
        == .unmerged)
  }

  @Test("より深いディレクトリ scope を優先する")
  func deeperDirectoryScopeWins() throws {
    let overlay = WorktreeFileGitStateOverlay(entries: [
      .ignored(path: try path("build"), scope: .directory),
      .untracked(path: try path("build/generated"), scope: .directory),
    ])

    #expect(overlay.state(for: try path("build/other"), kind: .file) == .ignored)
    #expect(overlay.state(for: try path("build/generated/file"), kind: .file) == .untracked)
  }

  @Test("同じ深さでは ignored を優先する")
  func ignoredWinsEqualDepthTie() throws {
    let prefix = try path("build")
    let overlay = WorktreeFileGitStateOverlay(entries: [
      .untracked(path: prefix, scope: .directory),
      .ignored(path: prefix, scope: .directory),
    ])

    #expect(overlay.state(for: try path("build/file"), kind: .file) == .ignored)

    let reversed = WorktreeFileGitStateOverlay(entries: overlay.entries.reversed())
    #expect(reversed.state(for: try path("build/file"), kind: .file) == .ignored)
  }

  @Test("完全一致 scope は配下へ波及しない")
  func exactScopeDoesNotMatchDescendants() throws {
    let overlay = WorktreeFileGitStateOverlay(entries: [
      .untracked(path: try path("loose"), scope: .exact)
    ])

    #expect(overlay.state(for: try path("loose"), kind: .file) == .untracked)
    #expect(overlay.state(for: try path("loose/child"), kind: .file) == .tracked(.unchanged))
  }

  @Test("ディレクトリに配下の状態を集約しない")
  func doesNotAggregateDescendantChanges() throws {
    let overlay = WorktreeFileGitStateOverlay(entries: [
      .changed(
        path: try path("Sources/main.swift"), indexStatus: .unchanged, worktreeStatus: .modified)
    ])

    #expect(overlay.state(for: try path("Sources"), kind: .directory) == nil)
  }

  @Test("結合文字が区切りに隣接してもスラッシュを区切りとして扱う")
  func handlesCombiningMarksNextToSeparators() throws {
    let overlay = WorktreeFileGitStateOverlay(entries: [
      .ignored(path: try path("foo"), scope: .directory),
      .untracked(path: try path("foo/\u{0301}"), scope: .directory),
      .untracked(path: try path("\u{0301}"), scope: .directory),
    ])
    #expect(overlay.state(for: try path("foo/\u{0301}/start.txt"), kind: .file) == .untracked)
    #expect(overlay.state(for: try path("\u{0301}/bar"), kind: .file) == .untracked)
    #expect(overlay.state(for: try path("foo/\u{0301}start.txt"), kind: .file) == .ignored)
  }

  @Test("サブモジュール自身と配下は状態なしにする")
  func submodulePathsHaveNoState() throws {
    let overlay = WorktreeFileGitStateOverlay(entries: [
      .submodule(path: try path("sub"))
    ])

    #expect(overlay.state(for: try path("sub"), kind: .directory) == nil)
    #expect(overlay.state(for: try path("sub/s.txt"), kind: .file) == nil)
    #expect(overlay.state(for: try path("sub/deep/x.txt"), kind: .file) == nil)
    #expect(overlay.state(for: try path("subtle.txt"), kind: .file) == .tracked(.unchanged))
  }

  @Test("サブモジュール自身が status に現れたときはその状態を使う")
  func reportedSubmoduleKeepsItsStatus() throws {
    let overlay = WorktreeFileGitStateOverlay(entries: [
      .changed(path: try path("sub"), indexStatus: .unchanged, worktreeStatus: .modified),
      .submodule(path: try path("sub")),
    ])

    #expect(
      overlay.state(for: try path("sub"), kind: .directory)
        == .tracked(.init(index: .unchanged, worktree: .modified)))
    #expect(overlay.state(for: try path("sub/s.txt"), kind: .file) == nil)
  }

  @Test("NFD で与えたパスは NFC の git 出力と同じキーになる")
  func normalizesToPrecomposedForm() throws {
    let decomposed = try path("e\u{0301}dir")
    let precomposed = try path("\u{00E9}dir")
    #expect(decomposed == precomposed)
    #expect(decomposed.hashValue == precomposed.hashValue)
    #expect(Array(decomposed.value.utf8) == Array("\u{00E9}dir".utf8))

    let overlay = WorktreeFileGitStateOverlay(entries: [
      .untracked(path: precomposed, scope: .directory)
    ])
    #expect(overlay.state(for: try path("e\u{0301}dir/f.txt"), kind: .file) == .untracked)
  }

  @Test(
    "正規化されていない相対パスを拒否する",
    arguments: ["", "/foo", "./foo", "foo/", "foo//bar", "foo/./bar", "foo/../bar"]
  )
  func rejectsNonCanonicalPaths(_ value: String) {
    #expect(WorktreeRelativePath(value) == nil)
  }
}

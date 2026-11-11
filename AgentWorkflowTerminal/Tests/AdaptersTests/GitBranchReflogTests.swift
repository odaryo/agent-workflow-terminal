import Foundation
import Testing

@testable import Adapters

// fixture は git 2.54.0 (`/usr/bin/git`) の隔離 repository
// (`GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1`) で
// `git reflog show --no-show-signature --format=%gs refs/heads/<branch> --` を採取 (Issue #829)。
// 出力は新しい順で、最終行が最古。
@Suite("§9.1.1 branch の reflog から分岐元の記録を読む")
struct GitBranchReflogTests {
  @Test(
    "最終行が作成の項目なら、その起点をそのまま返す",
    arguments: [
      // `git branch b1 origin/main` の直後。
      ("git-2.54.0-reflog-show-gs-created.txt", "origin/main"),
      // 上の branch で2回 commit した後。
      ("git-2.54.0-reflog-show-gs-commits.txt", "origin/main"),
      // さらに `git branch -m b1 d2` した後。
      ("git-2.54.0-reflog-show-gs-renamed.txt", "origin/main"),
      // さらに `git branch -c d2 d3` で写した先。
      ("git-2.54.0-reflog-show-gs-copied.txt", "origin/main"),
      // `git branch g1 'main@{1 minute ago}'`。解決できるかは呼び出し側が決める。
      ("git-2.54.0-reflog-show-gs-created-from-reflog-selector.txt", "main@{1 minute ago}"),
      // `git branch c3 @`。`@` も展開されずに記録される。
      ("git-2.54.0-reflog-show-gs-created-from-at.txt", "@"),
      // `git branch g3 日本語` を `git -c core.quotepath=true reflog show ...` で読んだもの。引用されない。
      ("git-2.54.0-reflog-show-gs-created-from-japanese.txt", "日本語"),
    ])
  func readsCreatedFrom(name: String, expected: String) throws {
    let output = try fixture(named: name)

    #expect(GitBranchReflog.createdFromStartPoint(subjects: output) == expected)
  }

  @Test(
    "最終行が作成の項目でなければ読まない",
    arguments: [
      // 2回 commit した branch で `git reflog delete refs/heads/e3@{2}` (作成の項目) を消した後。
      // 最終行は `commit: c1`。
      "git-2.54.0-reflog-show-gs-creation-deleted.txt",
      // `git reflog expire --expire=now refs/heads/e2`。stdout は空で rc=0。
      "git-2.54.0-reflog-show-gs-expired.txt",
      // `git -c core.logAllRefUpdates=false branch e1 origin/main`。stdout は空で rc=0。
      "git-2.54.0-reflog-show-gs-no-reflog.txt",
      // `git update-ref -m 'branch: Created from ' ...`。git が末尾の空白を落として記録する。
      "git-2.54.0-reflog-show-gs-created-from-empty-message.txt",
    ])
  func ignoresWithoutCreation(name: String) throws {
    let output = try fixture(named: name)

    #expect(GitBranchReflog.createdFromStartPoint(subjects: output) == nil)
  }

  @Test("末尾の改行が無くても最終行を読む")
  func readsWithoutTrailingNewline() throws {
    let output = try fixture(named: "git-2.54.0-reflog-show-gs-commits.txt")
    try #require(output.hasSuffix("\n"))

    #expect(
      GitBranchReflog.createdFromStartPoint(subjects: String(output.dropLast())) == "origin/main")
  }

  @Test(
    "作成の項目が最終行より上にあっても遡らない",
    arguments: [
      "branch: Created from main\ncommit: c1\n",
      "branch: Created from main\nBranch: renamed refs/heads/a to refs/heads/b\n",
    ])
  func doesNotLookAboveLastLine(output: String) {
    #expect(GitBranchReflog.createdFromStartPoint(subjects: output) == nil)
  }

  @Test("末尾の空行は最終行に数えない")
  func skipsTrailingEmptyLines() {
    #expect(
      GitBranchReflog.createdFromStartPoint(subjects: "commit: c1\nbranch: Created from main\n\n")
        == "main")
  }

  @Test(
    "作成の項目の形をしていない行は読まない",
    arguments: [
      "",
      "\n",
      "branch: Created from \n",
      "branch: Created from",
      "Branch: renamed refs/heads/a to refs/heads/b\n",
      "Branch: Created from main\n",
      "commit: c2\n",
    ])
  func ignoresOtherShapes(output: String) {
    #expect(GitBranchReflog.createdFromStartPoint(subjects: output) == nil)
  }

  private func fixture(named name: String) throws -> String {
    let url = try #require(
      Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return String(decoding: try Data(contentsOf: url), as: UTF8.self)
  }
}

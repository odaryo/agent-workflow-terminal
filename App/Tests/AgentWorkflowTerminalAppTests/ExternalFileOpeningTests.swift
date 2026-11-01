import Foundation
import Testing

@testable import AgentWorkflowTerminalApp

@Suite("既定アプリで開くファイルの判定と解決 (§7.3)")
struct ExternalFileOpeningTests {
  @Test(
    "html と md の最後の拡張子だけを対象にする",
    arguments: [
      ("a.html", true), ("A.HTML", true), ("docs/readme.md", true), ("x.Md", true),
      ("a.htm", false), ("a.markdown", false), ("a.txt", false), ("Makefile", false),
      (".md", false), (".html", false), ("docs/.md", false), ("..md", false),
      ("a.md/", false), ("dir.md/", false), ("a.md.txt", false), ("a.txt.md", true),
    ])
  func extensions(path: String, expected: Bool) {
    #expect(ExternalFileOpening.isSupported(path: path) == expected)
  }

  @Test(
    "現在の通常ファイルだけを worktree 内から解決する",
    arguments: [
      "existing.md", "missing.md", "dir.md", "../outside.md", "outside-link.md", "inside-link.md",
      "../worktree-other/file.md", "nonexist/../linkdir/x.md", "existing.md/../linkdir/x.md",
      "dangling-link.md/../linkdir/x.md", "linkdir/x.md", "./existing.md",
      "a//existing.md", "/etc/hosts", "", "existing.md/", "dangling-link.md", "loop.md",
      "sibling-link.md",
    ])
  func resolve(path: String) throws {
    let manager = FileManager.default
    let temporary = manager.temporaryDirectory.appending(path: UUID().uuidString)
      .resolvingSymlinksInPath()
    let root = temporary.appending(path: "worktree")
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: temporary) }
    let existing = root.appending(path: "existing.md")
    try Data("content".utf8).write(to: existing)
    try Data().write(to: temporary.appending(path: "outside.md"))
    try manager.createDirectory(
      at: root.appending(path: "dir.md"), withIntermediateDirectories: true)
    let sibling = temporary.appending(path: "worktree-other")
    try manager.createDirectory(at: sibling, withIntermediateDirectories: true)
    try Data().write(to: sibling.appending(path: "file.md"))
    try manager.createSymbolicLink(
      at: root.appending(path: "outside-link.md"),
      withDestinationURL: temporary.appending(path: "outside.md"))
    try manager.createSymbolicLink(
      at: root.appending(path: "inside-link.md"), withDestinationURL: existing)

    let outside = temporary.appending(path: "outside")
    try manager.createDirectory(at: outside, withIntermediateDirectories: true)
    try Data().write(to: outside.appending(path: "x.md"))
    try manager.createSymbolicLink(
      atPath: root.appending(path: "linkdir").path, withDestinationPath: "../outside")
    try manager.createSymbolicLink(
      atPath: root.appending(path: "dangling-link.md").path, withDestinationPath: "missing.md")
    try manager.createSymbolicLink(
      atPath: root.appending(path: "loop.md").path, withDestinationPath: "loop.md")
    // 字面の判定を通り、realpath 後の境界の比較だけが拒否する入力 (root と前方一致する兄弟)。
    try manager.createSymbolicLink(
      atPath: root.appending(path: "sibling-link.md").path,
      withDestinationPath: "../worktree-other/file.md")

    switch path {
    case "existing.md", "inside-link.md":
      let resolved = try ExternalFileOpening.resolve(worktreeRoot: root, relativePath: path)
      #expect(resolved.resolvingSymlinksInPath() == existing.resolvingSymlinksInPath())
    case "missing.md", "dir.md", "dangling-link.md", "loop.md":
      #expect(throws: ExternalFileOpening.ResolutionError.missingFile) {
        try ExternalFileOpening.resolve(worktreeRoot: root, relativePath: path)
      }
    default:
      #expect(throws: ExternalFileOpening.ResolutionError.outsideWorktree) {
        try ExternalFileOpening.resolve(worktreeRoot: root, relativePath: path)
      }
    }
  }

  @Test("正規化していない root と symlink の root を解決する", arguments: [false, true])
  func unnormalizedRoot(useSymlink: Bool) throws {
    let manager = FileManager.default
    let temporary = manager.temporaryDirectory.appending(path: UUID().uuidString)
    let worktree = temporary.appending(path: "worktree")
    try manager.createDirectory(at: worktree, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: temporary) }
    let existing = worktree.appending(path: "existing.md")
    try Data().write(to: existing)
    let link = temporary.appending(path: "worktree-link")
    try manager.createSymbolicLink(at: link, withDestinationURL: worktree)

    let resolved = try ExternalFileOpening.resolve(
      worktreeRoot: useSymlink ? link : worktree, relativePath: "existing.md")
    let pointer = try #require(realpath(existing.path, nil))
    defer { free(pointer) }
    #expect(resolved.path == String(cString: pointer))
  }

  @Test("存在しない root は missingFile、不正な相対パスは先に outsideWorktree にする")
  func missingRoot() {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    #expect(throws: ExternalFileOpening.ResolutionError.missingFile) {
      try ExternalFileOpening.resolve(worktreeRoot: root, relativePath: "existing.md")
    }
    #expect(throws: ExternalFileOpening.ResolutionError.outsideWorktree) {
      try ExternalFileOpening.resolve(worktreeRoot: root, relativePath: "./existing.md")
    }
  }
}

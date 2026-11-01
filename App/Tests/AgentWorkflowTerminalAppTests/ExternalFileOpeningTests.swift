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
      (".md", false), ("docs/.md", false), ("a.md.txt", false), ("a.txt.md", true),
    ])
  func extensions(path: String, expected: Bool) {
    #expect(ExternalFileOpening.isSupported(path: path) == expected)
  }

  @Test(
    "現在の通常ファイルだけを worktree 内から解決する",
    arguments: [
      "existing.md", "missing.md", "dir.md", "../outside.md", "outside-link.md", "inside-link.md",
      "../worktree-other/file.md",
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

    switch path {
    case "existing.md", "inside-link.md":
      let resolved = try ExternalFileOpening.resolve(worktreeRoot: root, relativePath: path)
      #expect(resolved.resolvingSymlinksInPath() == existing.resolvingSymlinksInPath())
    case "missing.md", "dir.md":
      #expect(throws: ExternalFileOpening.ResolutionError.missingFile) {
        try ExternalFileOpening.resolve(worktreeRoot: root, relativePath: path)
      }
    default:
      #expect(throws: ExternalFileOpening.ResolutionError.outsideWorktree) {
        try ExternalFileOpening.resolve(worktreeRoot: root, relativePath: path)
      }
    }
  }
}

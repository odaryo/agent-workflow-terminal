import Adapters
import Darwin
import Foundation
import TerminalCore
import Testing

@Suite("§7.1 File Browser の1階層列挙")
struct FileBrowserDirectoryReaderTests {
  @Test("隠しファイルと成果物を含む直下だけを決定的に列挙する")
  func listsOneLevel() throws {
    try withTemporaryDirectory { root in
      try FileManager.default.createDirectory(
        at: root.appending(path: "build"), withIntermediateDirectories: false)
      try Data().write(to: root.appending(path: ".hidden"))
      try Data().write(to: root.appending(path: "z.log"))
      try Data().write(to: root.appending(path: "build/nested.o"))

      let children = try FileBrowserDirectoryReader(worktreeRoot: root).children(in: nil)

      #expect(children.map(\.name) == ["build", ".hidden", "z.log"])
      #expect(children.map(\.kind) == [.directory, .file, .file])
    }
  }

  @Test("worktree root 直下の .git だけを列挙から外す")
  func hidesOnlyTheRootGitEntry() throws {
    try withTemporaryDirectory { root in
      // worktree では .git はディレクトリではなくファイル (`gitdir: ...`)。
      try Data("gitdir: /elsewhere\n".utf8).write(to: root.appending(path: ".git"))
      try FileManager.default.createDirectory(
        at: root.appending(path: "docs"), withIntermediateDirectories: false)
      try Data().write(to: root.appending(path: "docs/.git"))
      let reader = FileBrowserDirectoryReader(worktreeRoot: root)

      #expect(try reader.children(in: nil).map(\.name) == ["docs"])
      #expect(try reader.children(in: path("docs")).map(\.name) == [".git"])
    }
  }

  @Test("ディレクトリへの symlink をファイルとして扱い、辿らない")
  func doesNotFollowDirectorySymbolicLink() throws {
    try withTemporaryDirectory { root in
      try FileManager.default.createDirectory(
        at: root.appending(path: "target"), withIntermediateDirectories: false)
      try FileManager.default.createDirectory(
        at: root.appending(path: "target/nested"), withIntermediateDirectories: false)
      try FileManager.default.createSymbolicLink(
        at: root.appending(path: "link"), withDestinationURL: root.appending(path: "target"))

      let reader = FileBrowserDirectoryReader(worktreeRoot: root)
      let children = try reader.children(in: nil)

      #expect(children.first { $0.name == "link" }?.kind == .file)
      let expectedError = FileBrowserDirectoryReaderError.symbolicLink(
        root.appending(path: "link").path)
      #expect(throws: expectedError) {
        _ = try reader.children(in: path("link/nested"))
      }
    }
  }

  @Test("空ディレクトリと読めないディレクトリを別の失敗として区別する")
  func distinguishesEmptyAndUnreadableDirectories() throws {
    try withTemporaryDirectory { root in
      let empty = root.appending(path: "empty")
      let unreadable = root.appending(path: "unreadable")
      try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
      try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: false)
      #expect(chmod(unreadable.path, 0) == 0)
      defer { _ = chmod(unreadable.path, S_IRWXU) }
      let reader = FileBrowserDirectoryReader(worktreeRoot: root)

      #expect(try reader.children(in: path("empty")).isEmpty)
      #expect(throws: FileBrowserDirectoryReaderError.unreadable(unreadable.path)) {
        _ = try reader.children(in: path("unreadable"))
      }
    }
  }

  private func path(_ value: String) -> WorktreeRelativePath {
    guard let path = WorktreeRelativePath(value) else { preconditionFailure("不正なテストパス") }
    return path
  }
}

private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
  let root = URL(fileURLWithPath: "/private/tmp/awt-browser-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: root) }
  try body(root)
}

import Adapters
import Darwin
import Foundation
import TerminalCore
import Testing

@Suite("worktree inventoryの削除 (設計書 §16.1 / Issue #406)")
struct WorktreeInventoryStoreRemovalTests: WorktreeInventoryStoreTestHelpers {

  // MARK: - 削除 (Issue #406)

  private func projectFileURL(in directory: URL) -> URL {
    directory
      .appendingPathComponent("projects", isDirectory: true)
      .appendingPathComponent("deadbeef", isDirectory: true)
      .appendingPathComponent("worktree-inventory.json")
  }

  /// `FileManager.fileExists` は symlink を辿るので、壊れた symlink が残っていても `false` になる。
  private func nothingExists(at url: URL) -> Bool {
    var status = stat()
    return lstat(url.path, &status) != 0 && errno == ENOENT
  }

  @Test("保存したファイルとProjectのディレクトリを消し、projects/は残す")
  func removeDeletesFileAndProjectDirectory() async throws {
    try await withTemporaryDirectory { directory in
      let fileURL = projectFileURL(in: directory)
      let store = WorktreeInventoryStore(fileURL: fileURL)
      try await store.save(try inventory(active: true))
      try #require(!nothingExists(at: fileURL))

      let removal = try await store.remove()

      #expect(removal.keptDirectory == nil)
      #expect(nothingExists(at: fileURL))
      #expect(nothingExists(at: fileURL.deletingLastPathComponent()))
      let projects = fileURL.deletingLastPathComponent().deletingLastPathComponent()
      #expect(!nothingExists(at: projects))
      #expect(try await store.load() == nil)
    }
  }

  @Test("何も無い状態での削除は成功する")
  func removeSucceedsWhenNothingExists() async throws {
    try await withTemporaryDirectory { directory in
      let fileURL = projectFileURL(in: directory)
      let store = WorktreeInventoryStore(fileURL: fileURL)

      let removal = try await store.remove()

      #expect(removal.keptDirectory == nil)
      #expect(nothingExists(at: fileURL.deletingLastPathComponent()))
    }
  }

  @Test("ファイルが無くても空のProjectディレクトリは消す")
  func removeDeletesEmptyDirectoryWhenFileIsAbsent() async throws {
    try await withTemporaryDirectory { directory in
      let fileURL = projectFileURL(in: directory)
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      let store = WorktreeInventoryStore(fileURL: fileURL)

      let removal = try await store.remove()

      #expect(removal.keptDirectory == nil)
      #expect(nothingExists(at: fileURL.deletingLastPathComponent()))
    }
  }

  @Test("Projectディレクトリに別のファイルがあれば、ファイルだけ消してディレクトリは残す")
  func removeKeepsNonEmptyDirectory() async throws {
    try await withTemporaryDirectory { directory in
      let fileURL = projectFileURL(in: directory)
      let store = WorktreeInventoryStore(fileURL: fileURL)
      try await store.save(try inventory(active: true))
      let other = fileURL.deletingLastPathComponent().appendingPathComponent("other.txt")
      try Data("keep".utf8).write(to: other)

      let removal = try await store.remove()

      #expect(nothingExists(at: fileURL))
      let projectDirectory = fileURL.deletingLastPathComponent()
      #expect(
        removal.keptDirectory
          == WorktreeInventoryRemoval.KeptDirectory(
            path: projectDirectory.path, entries: ["other.txt"]))
      let remaining = try FileManager.default.contentsOfDirectory(atPath: projectDirectory.path)
      #expect(remaining == ["other.txt"])
    }
  }

  @Test("リンク先の無いsymlinkも消す")
  func removeDeletesBrokenSymbolicLink() async throws {
    try await withTemporaryDirectory { directory in
      let fileURL = projectFileURL(in: directory)
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      let target = directory.appendingPathComponent("nowhere.json")
      try FileManager.default.createSymbolicLink(
        atPath: fileURL.path, withDestinationPath: target.path)
      try #require(!nothingExists(at: fileURL))
      let store = WorktreeInventoryStore(fileURL: fileURL)

      let removal = try await store.remove()

      #expect(removal.keptDirectory == nil)
      #expect(nothingExists(at: fileURL))
      #expect(nothingExists(at: fileURL.deletingLastPathComponent()))
      #expect(nothingExists(at: target))
    }
  }

  @Test("symlinkはリンク自体だけを消し、リンク先は残す")
  func removeDoesNotFollowSymbolicLink() async throws {
    try await withTemporaryDirectory { directory in
      let fileURL = projectFileURL(in: directory)
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      let target = directory.appendingPathComponent("elsewhere.json")
      try Data("keep".utf8).write(to: target)
      try FileManager.default.createSymbolicLink(
        atPath: fileURL.path, withDestinationPath: target.path)
      let store = WorktreeInventoryStore(fileURL: fileURL)

      let removal = try await store.remove()

      #expect(removal.keptDirectory == nil)
      #expect(nothingExists(at: fileURL))
      #expect(try Data(contentsOf: target) == Data("keep".utf8))
    }
  }

  @Test("save()が残した自分の一時ファイルも消して、ディレクトリまで消す")
  func removeDeletesOwnTemporaryFiles() async throws {
    try await withTemporaryDirectory { directory in
      let fileURL = projectFileURL(in: directory)
      let store = WorktreeInventoryStore(fileURL: fileURL)
      try await store.save(try inventory(active: true))
      let projectDirectory = fileURL.deletingLastPathComponent()
      for uuid in [UUID().uuidString, UUID().uuidString.lowercased()] {
        try Data("partial".utf8).write(
          to: projectDirectory.appendingPathComponent(".worktree-inventory.json.\(uuid).tmp"))
      }

      let removal = try await store.remove()

      #expect(removal.keptDirectory == nil)
      #expect(nothingExists(at: projectDirectory))
    }
  }

  @Test("一時ファイルの形に当たらないものは消さず、残った名前を並べて返す")
  func removeKeepsAndReportsForeignEntries() async throws {
    try await withTemporaryDirectory { directory in
      let fileURL = projectFileURL(in: directory)
      let store = WorktreeInventoryStore(fileURL: fileURL)
      try await store.save(try inventory(active: true))
      let projectDirectory = fileURL.deletingLastPathComponent()
      let ownTemporary = ".worktree-inventory.json.\(UUID().uuidString).tmp"
      let foreign = [
        ".worktree-inventory.json.not-a-uuid.tmp",
        ".other.json.\(UUID().uuidString).tmp",
        "worktree-inventory.json.\(UUID().uuidString).tmp",
        ".worktree-inventory.json.\(UUID().uuidString).tmp.bak",
        ".DS_Store",
        "zz-notes.txt",
      ]
      for name in foreign + [ownTemporary] {
        try Data("x".utf8).write(to: projectDirectory.appendingPathComponent(name))
      }

      let removal = try await store.remove()

      #expect(
        removal.keptDirectory
          == WorktreeInventoryRemoval.KeptDirectory(
            path: projectDirectory.path, entries: foreign.sorted()))
      #expect(nothingExists(at: fileURL))
      #expect(nothingExists(at: projectDirectory.appendingPathComponent(ownTemporary)))
      let remaining = try FileManager.default.contentsOfDirectory(atPath: projectDirectory.path)
      #expect(remaining.sorted() == foreign.sorted())
    }
  }

  @Test("中間要素のsymlinkは辿り、リンク先のディレクトリの中身を消す")
  func removeFollowsIntermediateSymbolicLink() async throws {
    try await withTemporaryDirectory { directory in
      let realDirectory = directory.appendingPathComponent("real", isDirectory: true)
      try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
      let fileURL = projectFileURL(in: directory)
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent().deletingLastPathComponent(),
        withIntermediateDirectories: true)
      try FileManager.default.createSymbolicLink(
        atPath: fileURL.deletingLastPathComponent().path,
        withDestinationPath: realDirectory.path)
      let store = WorktreeInventoryStore(fileURL: fileURL)
      try await store.save(try inventory(active: true))
      try #require(
        !nothingExists(at: realDirectory.appendingPathComponent("worktree-inventory.json")))

      let error = await capturedError { _ = try await store.remove() }

      // ファイルはリンク先から消える。`rmdir` は最後の要素 (symlink) を辿らず `ENOTDIR` になる。
      #expect(nothingExists(at: realDirectory.appendingPathComponent("worktree-inventory.json")))
      guard
        case .removeFailed(let path, let code) = try #require(
          error as? WorktreeInventoryStoreError)
      else {
        Issue.record("removeFailed を期待したが \(String(describing: error))")
        return
      }
      #expect(path == fileURL.deletingLastPathComponent().path)
      #expect(code == Int(ENOTDIR))
    }
  }

  @Test("保存先がディレクトリにすり替わっていたら、中身ごと消さずremoveFailedをthrowする")
  func removeDoesNotRecurseIntoDirectory() async throws {
    try await withTemporaryDirectory { directory in
      let fileURL = projectFileURL(in: directory)
      try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: true)
      let inner = fileURL.appendingPathComponent("inner.txt")
      try Data("keep".utf8).write(to: inner)
      let store = WorktreeInventoryStore(fileURL: fileURL)

      let error = await capturedError { _ = try await store.remove() }

      guard case .removeFailed(let path, _) = try #require(error as? WorktreeInventoryStoreError)
      else {
        Issue.record("removeFailed を期待したが \(String(describing: error))")
        return
      }
      #expect(path == fileURL.path)
      #expect(try Data(contentsOf: inner) == Data("keep".utf8))
    }
  }

  @Test("消せなかったらremoveFailedをthrowし、ファイルを残す")
  func removeThrowsWhenFileCannotBeDeleted() async throws {
    try await withTemporaryDirectory { directory in
      let fileURL = projectFileURL(in: directory)
      let store = WorktreeInventoryStore(fileURL: fileURL)
      try await store.save(try inventory(active: true))
      let projectDirectory = fileURL.deletingLastPathComponent()

      // 書き込み権の無いディレクトリからは中のファイルを unlink できない。root ではパーミッションが
      // 効かないので前提を明示する。
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o500], ofItemAtPath: projectDirectory.path)
      defer {
        try? FileManager.default.setAttributes(
          [.posixPermissions: 0o755], ofItemAtPath: projectDirectory.path)
      }
      try #require(!FileManager.default.isWritableFile(atPath: projectDirectory.path))

      let error = await capturedError { _ = try await store.remove() }

      guard
        case .removeFailed(let path, let code) = try #require(
          error as? WorktreeInventoryStoreError)
      else {
        Issue.record("removeFailed を期待したが \(String(describing: error))")
        return
      }
      #expect(path == fileURL.path)
      #expect(code == Int(EACCES))
      #expect(!nothingExists(at: fileURL))
    }
  }
}

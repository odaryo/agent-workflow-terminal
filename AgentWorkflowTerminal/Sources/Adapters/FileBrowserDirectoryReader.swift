import Foundation
import TerminalCore

public enum FileBrowserDirectoryReaderError: Error, Sendable, Equatable {
  case notDirectory(String)
  case symbolicLink(String)
  case unreadable(String)
  case listingFailed(String)
}

public struct FileBrowserDirectoryReader: Sendable {
  public let worktreeRoot: URL

  public init(worktreeRoot: URL) {
    self.worktreeRoot = worktreeRoot
  }

  public func children(in relativeDirectory: WorktreeRelativePath?) throws -> [FileBrowserChild] {
    if let relativeDirectory {
      try rejectSymbolicLinkComponents(relativeDirectory)
    }
    let directory = relativeDirectory.map { worktreeRoot.appending(path: $0.value) } ?? worktreeRoot
    let path = directory.path
    do {
      let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isSymbolicLink != true else {
        throw FileBrowserDirectoryReaderError.symbolicLink(path)
      }
      guard values.isDirectory == true else {
        throw FileBrowserDirectoryReaderError.notDirectory(path)
      }
      guard FileManager.default.isReadableFile(atPath: path) else {
        throw FileBrowserDirectoryReaderError.unreadable(path)
      }
      let urls = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
        options: [])
      return try urls.filter { url in
        // worktree root 直下の `.git` は git の内部保管庫であって作業ツリーのファイルではなく、
        // git status も中身を報告しないため列挙から外す。worktree では file である点に注意。
        // 深い階層の同名ファイルはユーザーのものなので隠さない。
        relativeDirectory != nil || url.lastPathComponent != ".git"
      }.map { url in
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        // symlink 先を辿ると loop や worktree 外への脱出が起きるため、リンク自体は file とする。
        let kind: FileBrowserChildKind =
          values.isDirectory == true && values.isSymbolicLink != true ? .directory : .file
        return FileBrowserChild(name: url.lastPathComponent, kind: kind)
      }.fileBrowserSorted()
    } catch let error as FileBrowserDirectoryReaderError {
      throw error
    } catch {
      throw FileBrowserDirectoryReaderError.listingFailed(path)
    }
  }

  private func rejectSymbolicLinkComponents(
    _ relativeDirectory: WorktreeRelativePath
  ) throws {
    var candidate = worktreeRoot
    for component in NSString(string: relativeDirectory.value).pathComponents {
      candidate.append(path: component)
      do {
        let values = try candidate.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
          throw FileBrowserDirectoryReaderError.symbolicLink(candidate.path)
        }
      } catch let error as FileBrowserDirectoryReaderError {
        throw error
      } catch {
        throw FileBrowserDirectoryReaderError.listingFailed(candidate.path)
      }
    }
  }
}

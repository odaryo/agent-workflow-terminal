import AppKit
import Foundation
import SwiftUI

enum ExternalFileOpening {
  enum ResolutionError: Error, Equatable {
    case missingFile
    case outsideWorktree

    var message: String {
      switch self {
      case .missingFile:
        "作業ツリーにこのファイルがありません (削除または名前変更された可能性があります)"
      case .outsideWorktree:
        "worktree の外を指すため開きません"
      }
    }
  }

  static func isSupported(path: String) -> Bool {
    guard !path.hasSuffix("/") else { return false }
    let name = (path as NSString).lastPathComponent
    let suffix = (name as NSString).pathExtension.lowercased()
    return suffix == "html" || suffix == "md"
  }

  static func resolve(worktreeRoot: URL, relativePath: String) throws(ResolutionError) -> URL {
    let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
    guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
      throw .outsideWorktree
    }
    let root = try resolvedURL(path: worktreeRoot.path)
    let file = try resolvedURL(path: root.path + "/" + relativePath)
    guard file.pathComponents.starts(with: root.pathComponents) else {
      throw .outsideWorktree
    }
    guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey]),
      values.isRegularFile == true
    else {
      throw .missingFile
    }
    return file
  }

  private static func resolvedURL(path: String) throws(ResolutionError) -> URL {
    // resolvingSymlinksInPath() は途中の要素を解決できないと .. を字面で畳み、
    // symlink を辿らないパスを返すため、境界の判定には使わない。
    guard let pointer = realpath(path, nil) else { throw .missingFile }
    defer { free(pointer) }
    return URL(fileURLWithPath: String(cString: pointer))
  }
}

@MainActor
final class ExternalFileOpeningState: ObservableObject {
  @Published private(set) var failureReason: String?
  private var requestID = UUID()

  func reset() {
    requestID = UUID()
    failureReason = nil
  }

  func open(worktreeRoot: URL, relativePath: String) {
    reset()
    let url: URL
    do {
      url = try ExternalFileOpening.resolve(worktreeRoot: worktreeRoot, relativePath: relativePath)
    } catch {
      failureReason = error.message
      return
    }
    guard NSWorkspace.shared.urlForApplication(toOpen: url) != nil else {
      failureReason = "既定のアプリが見つかりません"
      return
    }
    let request = requestID
    NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
      let reason = error?.localizedDescription
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          // 選択変更や再試行より前の応答で、今の見出しの理由を上書きしない。
          guard self.requestID == request else { return }
          self.failureReason = reason
        }
      }
    }
  }
}

import Foundation

struct IntegrationWorkspace {
  private let directory: URL

  init() throws {
    directory = FileManager.default.temporaryDirectory
      .appending(path: "awt-main-pane-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  }

  func path(for name: String) -> String {
    directory.appending(path: name).path
  }

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }
}

/// 実行されたら痕跡ファイルが残る注入本文。許可された文字だけで組み立てる。
struct IntegrationExecutionProbe {
  let token: String
  private let hitPath: String

  init(workspace: IntegrationWorkspace, name: String) {
    token = "AWT_PASTE_\(name)_\(UInt32.random(in: 0..<1_000_000))"
    hitPath = workspace.path(for: "executed-\(name)")
  }

  var text: String { "\(token); touch '\(hitPath)'\n" }
  var didExecute: Bool { FileManager.default.fileExists(atPath: hitPath) }
}

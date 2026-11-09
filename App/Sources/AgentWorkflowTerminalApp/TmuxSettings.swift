import Adapters
import Foundation
import SwiftUI

enum TmuxPreferences {
  static let executablePathKey = "tmux.executablePath"

  static func overridePath(_ defaults: UserDefaults = .standard) -> String? {
    guard let path = defaults.string(forKey: executablePathKey), !path.isEmpty else { return nil }
    return path
  }
}

enum TmuxSettings {
  static func fileKind(_ path: String) -> TmuxExecutableFileKind {
    let manager = FileManager.default
    var isDirectory: ObjCBool = false
    guard manager.fileExists(atPath: path, isDirectory: &isDirectory) else { return .unusable }
    if isDirectory.boolValue { return .directory }
    return manager.isExecutableFile(atPath: path) ? .executableFile : .unusable
  }

  static func failureMessage(for resolution: TmuxExecutableResolution) -> String? {
    switch resolution {
    case .found:
      return nil
    case .notFound(let searched):
      let paths = searched.map(\.path).joined(separator: "、")
      return "tmux 実行ファイルが見つかりません。探した場所: \(paths)。"
        + "Homebrew では `brew install tmux` で導入できます。"
        + "別の場所にある tmux を使うときは、設定の「tmux」でパスを指定してください。"
    case .overrideNotUsable(let path, let reason):
      let explanation: String
      switch reason {
      case .notAbsolute:
        explanation = "絶対パスではありません"
      case .isDirectory:
        explanation = "ディレクトリです。tmux の実行ファイルのパスを指定してください"
      case .notExecutable:
        explanation = "存在しないか、実行できません"
      }
      return "設定で指定した tmux を使えません (\(path)): \(explanation)。"
        + "設定の「tmux」でパスを直すか、空にして既定の場所を探させてください。"
    }
  }
}

@MainActor
struct AppSettingsView: View {
  @ObservedObject var projects: ProjectsModel

  var body: some View {
    TabView {
      NotificationSettingsView()
        .tabItem { Label("通知", systemImage: "bell") }
      TmuxSettingsView()
        .tabItem { Label("tmux", systemImage: "terminal") }
      ProjectSettingsView(projects: projects)
        .tabItem { Label("Project", systemImage: "folder") }
    }
  }
}

@MainActor
struct TmuxSettingsView: View {
  @AppStorage(TmuxPreferences.executablePathKey) private var executablePath = ""

  private var defaultPaths: String {
    TmuxRunner.defaultExecutableCandidates.map(\.path).joined(separator: "、")
  }

  var body: some View {
    Form {
      Section {
        TextField("実行ファイルのパス", text: $executablePath, prompt: Text(defaultPaths))
      } footer: {
        Text("アプリの再起動後に反映されます。空にすると既定の場所 (\(defaultPaths)) を探します。")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .frame(width: 420)
  }
}

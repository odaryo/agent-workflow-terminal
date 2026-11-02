import Adapters
import Foundation
import TerminalCore

/// Project に依存しない、起動ごとに1つだけ作るもの (Issue #372)。Project ごとの `AppModel` は
/// これを共有する。
struct AppDependencies: Sendable {
  /// `--project` / `AWT_PROJECT_DIR` で指定された Project。登録して選択する。
  let launchProject: LaunchProjectArgument
  let tmuxExecutable: URL?
  let tmuxError: String?
  let paneStates: WorktreePaneStatesFeed?
  /// メインpaneの候補列挙とテキスト注入 (設計書 §9.2 / §12.7) が使う。tmux を起動できない
  /// 起動では `nil` で、その間は送信操作そのものが成立しない。
  let tmuxRunner: TmuxRunner?
  /// pane 一覧と連携変数 (§12.7) の読み取り。`paneStates` の feed と共有する (同じ `list-panes`
  /// キャッシュ)。
  let paneSource: TmuxWorktreePaneSource?
  /// `ps` のスナップショットを pane 状態の観測と共有する (§12.7 の現在の Agent プロセス)。
  let signalSource: TmuxAgentSignalSource?
  let sessionActivityProbe: TmuxSessionActivityProbe?
  /// `nil` の起動では Project の一覧と worktree の状態を保存できない。
  let applicationSupportDirectory: URL?
  let applicationSupportWarning: String?

  static func make() -> Self {
    let launchProject = resolveLaunchProject()
    let standardApplicationSupport = try? FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: false
    )
    let applicationSupport: URL?
    let applicationSupportWarning: String?
    switch ApplicationSupportLocation.resolve(
      environment: ProcessInfo.processInfo.environment, standard: standardApplicationSupport)
    {
    case .standard(let url):
      applicationSupport = url
      applicationSupportWarning = nil
    case .overridden(let url):
      applicationSupport = url
      applicationSupportWarning = nil
      NSLog("[app] Application Support を上書き: %@", url.path)
    case .invalid(let value):
      applicationSupport = nil
      applicationSupportWarning =
        "AWT_APPLICATION_SUPPORT_DIR が絶対パスではないため、"
        + "この起動では Project の一覧と worktree の状態を保存しません: \(value)"
    }
    return make(
      launchProject: launchProject, applicationSupport: applicationSupport,
      applicationSupportWarning: applicationSupportWarning)
  }

  private static func make(
    launchProject: LaunchProjectArgument, applicationSupport: URL?,
    applicationSupportWarning: String?
  ) -> Self {
    let server: TmuxServer
    switch TmuxServerEnvironment.resolve(environment: ProcessInfo.processInfo.environment) {
    case .server(let resolved):
      server = resolved
      if case .socketName(let name) = server {
        NSLog("[app] tmux server を隔離: -L %@", name)
      }
    case .invalid(let value):
      return withoutTmux(
        launchProject: launchProject, applicationSupport: applicationSupport,
        applicationSupportWarning: applicationSupportWarning,
        error: "AWT_TMUX_SOCKET_NAME が不正なため、この起動では tmux を使いません: \(value)")
    }
    let executable = TmuxRunner.defaultExecutableCandidates.first {
      FileManager.default.isExecutableFile(atPath: $0.path)
    }
    guard let executable else {
      return withoutTmux(
        launchProject: launchProject, applicationSupport: applicationSupport,
        applicationSupportWarning: applicationSupportWarning,
        error: "tmux 実行ファイルが見つかりません。tmux をインストールしてください。")
    }

    do {
      let runner = try TmuxRunner(
        server: server,
        processRunner: FoundationProcessRunner(),
        executableCandidates: [executable]
      )
      let signalSource = TmuxAgentSignalSource(
        tmuxRunner: runner,
        processRunner: FoundationProcessRunner()
      )
      let paneSource = TmuxWorktreePaneSource(runner: runner)
      return Self(
        launchProject: launchProject,
        tmuxExecutable: executable,
        tmuxError: nil,
        paneStates: makeWorktreePaneStatesFeed(paneSource: paneSource, signalSource: signalSource),
        tmuxRunner: runner,
        paneSource: paneSource,
        signalSource: signalSource,
        sessionActivityProbe: TmuxSessionActivityProbe(
          tmuxRunner: runner, processRunner: FoundationProcessRunner()),
        applicationSupportDirectory: applicationSupport,
        applicationSupportWarning: applicationSupportWarning
      )
    } catch {
      return withoutTmux(
        launchProject: launchProject, applicationSupport: applicationSupport,
        applicationSupportWarning: applicationSupportWarning,
        error: "tmux を利用できません: \(error)")
    }
  }

  private static func withoutTmux(
    launchProject: LaunchProjectArgument, applicationSupport: URL?,
    applicationSupportWarning: String?, error: String
  ) -> Self {
    Self(
      launchProject: launchProject,
      tmuxExecutable: nil,
      tmuxError: error,
      paneStates: nil,
      tmuxRunner: nil,
      paneSource: nil,
      signalSource: nil,
      sessionActivityProbe: nil,
      applicationSupportDirectory: applicationSupport,
      applicationSupportWarning: applicationSupportWarning
    )
  }

  /// 指定が無いことはエラーにしない。登録済みの Project を開く (Issue #372)。
  private static func resolveLaunchProject() -> LaunchProjectArgument {
    let arguments = ProcessInfo.processInfo.arguments
    let path: String?
    if let argumentIndex = arguments.indices.first(where: { arguments[$0] == "--project" }) {
      guard arguments.indices.contains(argumentIndex + 1) else {
        return .invalid("--project に絶対パスを指定してください。")
      }
      path = arguments[argumentIndex + 1]
    } else {
      path = ProcessInfo.processInfo.environment["AWT_PROJECT_DIR"]
    }
    guard let path, !path.isEmpty else { return .none }
    guard path.hasPrefix("/") else {
      return .invalid("Project には絶対パスを指定してください: \(path)")
    }
    return .directory(URL(fileURLWithPath: path))
  }
}

enum LaunchProjectArgument: Sendable {
  case none
  case directory(URL)
  case invalid(String)
}

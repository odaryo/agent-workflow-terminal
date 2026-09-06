import Adapters
import AppKit
import GhosttyRenderer
import SwiftUI
import TerminalCore

@main
struct AgentWorkflowTerminalApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var model: AppModel

  init() {
    _model = StateObject(wrappedValue: AppModel(dependencies: AppDependencies.make()))
  }

  var body: some Scene {
    WindowGroup("Agent Workflow Terminal") {
      ProjectView(model: model)
        .frame(minWidth: 480, minHeight: 320)
    }
    .defaultSize(width: 900, height: 560)
  }
}

private struct AppDependencies: Sendable {
  let projectDirectory: URL?
  let projectError: String?
  let tmuxExecutable: URL?
  let tmuxError: String?
  let paneStates: WorktreePaneStatesFeed?

  static func make() -> Self {
    let project = resolveProjectDirectory()
    let executable = TmuxRunner.defaultExecutableCandidates.first {
      FileManager.default.isExecutableFile(atPath: $0.path)
    }
    guard let executable else {
      return Self(
        projectDirectory: project.directory,
        projectError: project.error,
        tmuxExecutable: nil,
        tmuxError: "tmux 実行ファイルが見つかりません。tmux をインストールしてください。",
        paneStates: nil
      )
    }

    do {
      let runner = try TmuxRunner(
        server: .userDefault,
        processRunner: FoundationProcessRunner(),
        executableCandidates: [executable]
      )
      let signalSource = TmuxAgentSignalSource(
        tmuxRunner: runner,
        processRunner: FoundationProcessRunner()
      )
      return Self(
        projectDirectory: project.directory,
        projectError: project.error,
        tmuxExecutable: executable,
        tmuxError: nil,
        paneStates: makeTemporaryPaneStatesFeed(runner: runner, signalSource: signalSource)
      )
    } catch {
      return Self(
        projectDirectory: project.directory,
        projectError: project.error,
        tmuxExecutable: nil,
        tmuxError: "tmux を利用できません: \(error)",
        paneStates: nil
      )
    }
  }

  private static func resolveProjectDirectory() -> (directory: URL?, error: String?) {
    let arguments = ProcessInfo.processInfo.arguments
    let path: String?
    if let argumentIndex = arguments.indices.first(where: { arguments[$0] == "--project" }) {
      guard arguments.indices.contains(argumentIndex + 1) else {
        return (nil, "--project に絶対パスを指定してください。")
      }
      path = arguments[argumentIndex + 1]
    } else {
      path = ProcessInfo.processInfo.environment["AWT_PROJECT_DIR"]
    }
    guard let path, !path.isEmpty else {
      return (nil, "Project が指定されていません。--project <絶対パス> または AWT_PROJECT_DIR を設定してください。")
    }
    guard path.hasPrefix("/") else {
      return (nil, "Project には絶対パスを指定してください: \(path)")
    }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
      isDirectory.boolValue,
      FileManager.default.isReadableFile(atPath: path),
      FileManager.default.isExecutableFile(atPath: path)
    else {
      return (nil, "Project のパスを利用できません: \(path)")
    }
    return (URL(fileURLWithPath: path).standardizedFileURL, nil)
  }
}

@MainActor
private final class AppModel: ObservableObject {
  @Published private(set) var worktrees: [TaskWorktree] = []
  @Published var selectedIdentity: WorktreeIdentity?
  @Published var openedIdentities: Set<WorktreeIdentity> = []
  @Published private(set) var message: String?

  let tmuxExecutable: URL?
  let paneStates: WorktreePaneStatesFeed?
  private let projectDirectory: URL?

  init(dependencies: AppDependencies) {
    projectDirectory = dependencies.projectDirectory
    tmuxExecutable = dependencies.tmuxExecutable
    paneStates = dependencies.paneStates
    message = dependencies.projectError ?? dependencies.tmuxError
  }

  func load() async {
    guard worktrees.isEmpty, let projectDirectory else { return }
    do {
      let detector = try GitWorktreeDetector(
        projectDirectory: projectDirectory,
        processRunner: FoundationProcessRunner()
      )
      let scan = try await detector.scan()
      for failure in scan.failures {
        NSLog("[app] worktree の検出に失敗: \(String(describing: failure))")
      }
      worktrees =
        reconcileDetectedWorktrees(detected: scan.detected, previous: nil)
        .inventory.taskWorktrees
      if let first = worktrees.first {
        selectedIdentity = first.identity
        openedIdentities.insert(first.identity)
      } else if message == nil {
        message = "タスク worktree がありません。"
      }
    } catch {
      let detail = "worktree を検出できません: \(error)"
      NSLog("[app] \(detail)")
      message = detail
    }
  }

  func select(_ worktree: TaskWorktree) {
    selectedIdentity = worktree.identity
    openedIdentities.insert(worktree.identity)
  }
}

private struct ProjectView: View {
  @ObservedObject var model: AppModel

  var body: some View {
    VStack(spacing: 0) {
      if !model.worktrees.isEmpty {
        ScrollView(.horizontal) {
          HStack(spacing: 4) {
            ForEach(model.worktrees, id: \.identity) { worktree in
              WorktreeTab(
                worktree: worktree,
                selected: model.selectedIdentity == worktree.identity,
                paneStates: model.paneStates
              ) {
                model.select(worktree)
              }
            }
          }
          .padding(6)
        }
        .scrollIndicators(.hidden)
        Divider()
      }

      if let message = model.message {
        ContentUnavailableView(
          "Agent Workflow Terminal", systemImage: "exclamationmark.triangle",
          description: Text(message))
      } else {
        ZStack {
          ForEach(model.worktrees, id: \.identity) { worktree in
            if model.openedIdentities.contains(worktree.identity) {
              TerminalTabContent(worktree: worktree, tmuxExecutable: model.tmuxExecutable)
                .opacity(model.selectedIdentity == worktree.identity ? 1 : 0)
                .allowsHitTesting(model.selectedIdentity == worktree.identity)
            }
          }
        }
      }
    }
    .task { await model.load() }
  }
}

private struct WorktreeTab: View {
  let worktree: TaskWorktree
  let selected: Bool
  let paneStates: WorktreePaneStatesFeed?
  let action: () -> Void
  @State private var representativeState: WorktreeRepresentativeState?

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Circle().fill(stateColor).frame(width: 8, height: 8)
        Text(
          worktree.detected.branch
            ?? URL(fileURLWithPath: worktree.detected.worktreePath).lastPathComponent)
        Text(stateLabel).foregroundStyle(.secondary)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(selected ? Color.accentColor.opacity(0.18) : Color.clear)
      .clipShape(.rect(cornerRadius: 6))
    }
    .buttonStyle(.plain)
    .task(id: worktree.identity) {
      guard let paneStates else { return }
      let states = WorktreeRepresentativeStateFeed().states(from: paneStates(worktree))
      for await state in states {
        representativeState = state
      }
    }
  }

  private var stateLabel: String {
    guard let representativeState else { return "Idle" }
    return switch representativeState.state {
    case .working: "Working"
    case .question: "Question"
    case .permission: "Permission"
    case .completed: "Ready for Review"
    case .error: "Error"
    case .idle: "Idle"
    case .unknown: "Unknown"
    }
  }

  private var stateColor: Color {
    guard let representativeState else { return .secondary }
    return switch representativeState.category {
    case .needsAttention: .red
    case .readyForReview: .green
    case .working: .blue
    case .unknown: .orange
    case .idle: .secondary
    }
  }
}

private struct TerminalTabContent: View {
  let worktree: TaskWorktree
  let tmuxExecutable: URL?

  var body: some View {
    if let tmuxExecutable {
      GhosttyTerminalView(
        command: [
          tmuxExecutable.path, "-u", "new-session", "-A", "-s",
          TmuxSessionName(identity: worktree.identity).rawValue,
          "-c", worktree.detected.worktreePath,
        ],
        workingDirectory: worktree.detected.worktreePath
      )
    } else {
      ContentUnavailableView("tmux を利用できません", systemImage: "terminal")
    }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    setGhosttyApplicationFocus(true)
  }

  func applicationDidResignActive(_ notification: Notification) {
    setGhosttyApplicationFocus(false)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }
}

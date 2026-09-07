import Adapters
import Foundation
import SwiftUI
import TerminalCore

struct AppDependencies: Sendable {
  let projectDirectory: URL?
  let projectError: String?
  let tmuxExecutable: URL?
  let tmuxError: String?
  let paneStates: WorktreePaneStatesFeed?
  /// メインpaneの候補列挙とテキスト注入 (設計書 §9.2 / §12.7) が使う。tmux を起動できない
  /// 起動では `nil` で、その間は送信操作そのものが成立しない。
  let tmuxRunner: TmuxRunner?
  /// `~/Library/Application Support` に当たるディレクトリ。引けなかった場合は `nil` で、
  /// その起動では Active/Inactive を保存できない。
  let applicationSupportDirectory: URL?

  static func make() -> Self {
    let project = resolveProjectDirectory()
    let applicationSupport = try? FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: false
    )
    let executable = TmuxRunner.defaultExecutableCandidates.first {
      FileManager.default.isExecutableFile(atPath: $0.path)
    }
    guard let executable else {
      return Self(
        projectDirectory: project.directory,
        projectError: project.error,
        tmuxExecutable: nil,
        tmuxError: "tmux 実行ファイルが見つかりません。tmux をインストールしてください。",
        paneStates: nil,
        tmuxRunner: nil,
        applicationSupportDirectory: applicationSupport
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
        paneStates: makeWorktreePaneStatesFeed(runner: runner, signalSource: signalSource),
        tmuxRunner: runner,
        applicationSupportDirectory: applicationSupport
      )
    } catch {
      return Self(
        projectDirectory: project.directory,
        projectError: project.error,
        tmuxExecutable: nil,
        tmuxError: "tmux を利用できません: \(error)",
        paneStates: nil,
        tmuxRunner: nil,
        applicationSupportDirectory: applicationSupport
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
final class AppModel: ObservableObject {
  @Published private(set) var projectRoot: DetectedWorktree?
  @Published private(set) var worktrees: [TaskWorktree] = []
  @Published var selectedIdentity: WorktreeIdentity?
  @Published var openedIdentities: Set<WorktreeIdentity> = []
  @Published var viewerDrawerLayout = ViewerDrawerLayout.closed
  @Published private(set) var message: String?
  /// `message` と分ける。あちらはコンテンツ全体を `ContentUnavailableView` へ差し替えるため、
  /// 端末を出したまま伝えるべき失敗 (Active/Inactive の保存など) をあちらへ載せると、
  /// 致命的でない失敗で端末が消える。
  @Published private(set) var warning: String?

  let tmuxExecutable: URL?
  let paneStates: WorktreePaneStatesFeed?
  let diffModels = DiffViewerModelStore()
  let mainPanes: MainPaneCoordinator
  private let projectDirectory: URL?
  private let applicationSupportDirectory: URL?
  private var store: WorktreeInventoryStore?
  /// 保存されたファイルを読めなかった起動では `false`。読めなかったファイルを上書きすると、
  /// ユーザーが手で復旧できる可能性まで消える。
  private var canSave = false
  private var didStart = false
  private var pendingSave: Task<Void, Never>?

  /// 再スキャンの間隔。P1 の暫定値で、根拠は pane 観測 (`makeWorktreePaneStatesFeed`) と同じく
  /// 「体感で追随し、git への負荷が無視できる」程度でしかない。
  private static let rescanInterval = Duration.seconds(5)

  init(dependencies: AppDependencies) {
    projectDirectory = dependencies.projectDirectory
    applicationSupportDirectory = dependencies.applicationSupportDirectory
    tmuxExecutable = dependencies.tmuxExecutable
    paneStates = dependencies.paneStates
    mainPanes = MainPaneCoordinator(runner: dependencies.tmuxRunner)
    message = dependencies.projectError ?? dependencies.tmuxError
  }

  var inventory: WorktreeInventory {
    WorktreeInventory(projectRoot: projectRoot, taskWorktrees: worktrees)
  }

  func run() async {
    guard !didStart, let projectDirectory else { return }
    didStart = true

    let detector: GitWorktreeDetector
    do {
      detector = try GitWorktreeDetector(
        projectDirectory: projectDirectory,
        processRunner: FoundationProcessRunner()
      )
    } catch {
      report(scanFailure: "\(error)")
      return
    }

    switch await scan(with: detector) {
    case .failure(let error):
      report(scanFailure: "\(error)")
      return
    case .success(let scan):
      let saved = await prepare(for: scan)
      applyInitial(restoreWorktreeInventory(detected: scan.detected, saved: saved))
    }

    await observe(with: detector)
  }

  /// 起動時の1回だけ呼ぶ。2回目以降のスキャンは `reconcileDetectedWorktrees` の担当であり、
  /// 保存を `previous` として渡してはならない (`restoreWorktreeInventory` の doc 参照)。
  private func prepare(for scan: GitWorktreeScanResult) async -> PersistedWorktreeInventory? {
    // 保存先のキーは Project Root の安定 ID なので、Project Root を検出できない Project では
    // 保存先が決まらない。重複した `isProjectRoot` の扱いは `restoreWorktreeInventory` と
    // 揃えて最初の1件を採る。
    guard let projectRootIdentity = scan.detected.first(where: \.isProjectRoot)?.identity else {
      warning = "Project Root を検出できないため、この起動では Active/Inactive を保存しません。"
      return nil
    }
    guard let applicationSupportDirectory else {
      warning = "Application Support を利用できないため、この起動では Active/Inactive を保存しません。"
      return nil
    }

    let store = WorktreeInventoryStore(
      fileURL: WorktreeInventoryStore.defaultFileURL(
        applicationSupportDirectory: applicationSupportDirectory,
        projectRootIdentity: projectRootIdentity
      )
    )
    self.store = store
    do {
      let saved = try await store.load()
      canSave = true
      return saved
    } catch {
      // 「保存が無い」(`nil`) と同じ扱いにしない。読めなかったことをユーザーへ伝え、
      // この起動では上書きしない。
      warning = "保存された Active/Inactive を読めませんでした。この起動では保存しません: \(error)"
      return nil
    }
  }

  private func observe(with detector: GitWorktreeDetector) async {
    while !Task.isCancelled {
      try? await Task.sleep(for: Self.rescanInterval)
      guard !Task.isCancelled else { return }

      // スキャンが失敗した回は何もしない。空の一覧や部分的な結果を
      // `reconcileDetectedWorktrees` へ渡すと、全 worktree が消失扱いになり、次の回に
      // Inactive にしていた worktree が自動 Active 化される (同関数の doc 参照)。
      guard case .success(let scan) = await scan(with: detector) else { continue }

      let updated = reconcileDetectedWorktrees(detected: scan.detected, previous: inventory)
      guard updated.inventory != inventory else { continue }
      projectRoot = updated.inventory.projectRoot
      worktrees = updated.inventory.taskWorktrees
      save()
    }
  }

  private func scan(
    with detector: GitWorktreeDetector
  ) async -> Result<GitWorktreeScanResult, GitWorktreeScanError> {
    do {
      let scan = try await detector.scan()
      // 失敗した entry は `detected` に載らないため、そのまま渡すと消失扱いになる。
      // UI での扱いは Issue #137 の担当で、ここでは記録だけする。
      for failure in scan.failures {
        NSLog("[app] worktree の検出に失敗: \(String(describing: failure))")
      }
      return .success(scan)
    } catch {
      return .failure(error)
    }
  }

  private func applyInitial(_ result: WorktreeScanResult) {
    projectRoot = result.inventory.projectRoot
    worktrees = result.inventory.taskWorktrees
    if let projectRoot {
      selectedIdentity = projectRoot.identity
      openedIdentities.insert(projectRoot.identity)
    } else if let first = worktrees.first(where: \.detected.isReachable) {
      selectedIdentity = first.identity
      openedIdentities.insert(first.identity)
    } else if message == nil {
      message = worktrees.isEmpty ? "worktree がありません。" : "到達できる worktree がありません。"
    }
  }

  private func report(scanFailure detail: String) {
    NSLog("[app] worktree を検出できません: \(detail)")
    message = "worktree を検出できません: \(detail)"
  }

  func setActivation(_ activation: WorktreeActivation, of identity: WorktreeIdentity) {
    guard let index = worktrees.firstIndex(where: { $0.identity == identity }) else { return }
    let worktree = worktrees[index]
    // 到達不能な worktree の Active 化は設計書 §3.2 が認めていない (attach 先が実在しない)。
    guard activation != .active || worktree.detected.isReachable else { return }
    guard worktree.activation != activation else { return }
    worktrees[index] = TaskWorktree(detected: worktree.detected, activation: activation)
    save()
  }

  func dismissWarning() {
    warning = nil
  }

  private func save() {
    guard canSave, let store else { return }
    let snapshot = PersistedWorktreeInventory(inventory)
    // 直前の保存を待ってから書く。actor は1件ずつ実行するが到着順までは決めないため、
    // 待たずに投げると連続した操作で古い方が後に着いて上書きし得る。
    let previous = pendingSave
    pendingSave = Task {
      await previous?.value
      do {
        try await store.save(snapshot)
      } catch {
        warning = "Active/Inactive を保存できませんでした: \(error)"
      }
    }
  }

  /// 到達不能な worktree を開かないのは、`tmux new-session -c <存在しないディレクトリ>` が
  /// エラーにならず `$HOME` へ黙って落ちるためである (tmux 3.4 実測: client の cwd が
  /// `/private/tmp` でも exit 0 で session ができ、`pane_current_path` は `$HOME` になる)。そこで agent を走らせると、
  /// worktree の名前を持つタブが実際には別のディレクトリで作業することになる。しかも
  /// `new-session -A` なので、その誤った session に以後ずっと再 attach され続ける。
  func select(_ worktree: TaskWorktree) {
    guard worktree.detected.isReachable else { return }
    selectedIdentity = worktree.identity
    openedIdentities.insert(worktree.identity)
  }

  func selectProjectRoot() {
    guard let projectRoot else { return }
    selectedIdentity = projectRoot.identity
    openedIdentities.insert(projectRoot.identity)
  }

  var selectedWorktree: DetectedWorktree? {
    guard let selectedIdentity else { return nil }
    if let projectRoot, projectRoot.identity == selectedIdentity { return projectRoot }
    return worktrees.first { $0.identity == selectedIdentity }?.detected
  }

  /// Agent と判定済みの pane を候補一覧の印にするための観測経路 (設計書 §12.7)。Project Root は
  /// `TaskWorktree` ではないので `nil` になり、その場合は印の無い候補一覧になる。
  func agentPaneStates(of identity: WorktreeIdentity) -> AsyncStream<[PaneAgentState]>? {
    guard let paneStates, let worktree = worktrees.first(where: { $0.identity == identity }),
      worktree.detected.isReachable
    else { return nil }
    return paneStates(worktree)
  }
}

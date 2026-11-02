import Adapters
import Foundation
import SwiftUI
import TerminalCore

/// 登録済み Project 1件の、この起動での状態。
enum ProjectSlot {
  /// worktree の検出を回しているモデル。選択されていなくても作る — Overview (#189) と通知 (#190) が
  /// 非選択 Project の worktree 一覧を引くため。端末を作るのは選択中の Project の view だけ。
  case available(AppModel)
  /// 到達できない。一覧には理由付きで並べ、選択させない (Issue #372)。
  case unavailable(String)
}

/// 登録済み Project の集合と、メイン window に表示する1件の選択 (Issue #372)。
///
/// Project ごとの状態は `AppModel` が持ち、tmux runner と pane 状態 feed は `dependencies` を通して
/// 全 `AppModel` で共有する。
@MainActor
final class ProjectsModel: ObservableObject {
  @Published private(set) var registry = ProjectRegistry()
  @Published private(set) var slots: [WorktreeIdentity: ProjectSlot] = [:]
  /// 一覧を読み終えるまでは「登録が0件」と断定しない。読む前に空の状態を出すと、登録済みの
  /// ユーザーに一瞬「Project を追加」が見える (Issue #237 の M-1 と同じ種類の誤表示)。
  @Published private(set) var didLoad = false
  /// 端末を覆わずに伝える失敗 (保存できない、`--project` を解決できない、追加に失敗した等)。
  @Published private(set) var warning: String?

  /// Overview の行と通知の deep link が共用する移動。
  let navigator = AppNavigator()
  /// `nil` は通知を出さない起動 (bundle の外)。
  let notifier: PaneNotifier?

  private let dependencies: AppDependencies
  private let resolver = GitProjectResolver(processRunner: FoundationProcessRunner())
  private let store: ProjectRegistryStore?
  /// 保存された一覧を読めなかった起動では `false`。読めなかったファイルを上書きすると、
  /// ユーザーが手で復旧できる可能性まで消える (`AppModel.canSave` と同じ理由)。
  private var canSave = false
  private var pendingSave: Task<Void, Never>?
  /// 確認ダイアログの内容。非 `nil` の間だけダイアログを出す。
  @Published private(set) var pendingUnregister: ProjectUnregisterReview?
  private let startup = DetachedOnceTask()

  init(dependencies: AppDependencies) {
    self.dependencies = dependencies
    store = dependencies.applicationSupportDirectory.map {
      ProjectRegistryStore(
        fileURL: ProjectRegistryStore.defaultFileURL(applicationSupportDirectory: $0))
    }
    notifier = PaneNotifier.make(navigator: navigator)
    notifier?.attach(self)
  }

  var selectedModel: AppModel? {
    guard let selection = registry.selection, case .available(let model) = slots[selection]
    else { return nil }
    return model
  }

  var selectedProject: RegisteredProject? {
    registry.selection.flatMap(registry.project)
  }

  /// 登録済みで到達可能な全 Project のモデル。後続の Overview / 通知はここから worktree 一覧を引く。
  var availableModels: [AppModel] {
    registry.projects.compactMap { project in
      guard case .available(let model) = slots[project.commonDirectory] else { return nil }
      return model
    }
  }

  /// すぐ返る。`AppModel.run()` と同じく view の `.task` の寿命に乗せない (Issue #238)。
  func start() {
    startup.start { await self.load() }
  }

  private func load() async {
    var restored = ProjectRegistry()
    if let store {
      do {
        if let saved = try await store.load() {
          restored = ProjectRegistry(restoring: saved)
        }
        canSave = true
      } catch {
        warning = "登録済みの Project の一覧を読めませんでした。この起動では保存しません: \(error)"
      }
    } else if dependencies.applicationSupportWarning == nil {
      warning = "Application Support を利用できないため、この起動では Project の一覧を保存しません。"
    }

    for project in restored.projects {
      slots[project.commonDirectory] = await makeSlot(for: project)
    }
    registry = restored

    switch dependencies.launchProject {
    case .none: break
    case .invalid(let reason): warning = reason
    case .directory(let directory): await register(directory: directory)
    }

    if let applicationSupportWarning = dependencies.applicationSupportWarning {
      warning = [applicationSupportWarning, warning].compactMap { $0 }.joined(separator: "\n")
    }
    registry.reselect(selectable: isSelectable)
    didLoad = true
    save()
  }

  /// `--project` と「Project を追加…」の両方の入口。重複なら既存を選択する。
  func register(directory: URL) async {
    let project: RegisteredProject
    do {
      project = try await resolver.resolve(directory: directory)
    } catch {
      warning = "Project を追加できません: \(Self.describe(error))"
      return
    }

    switch registry.register(project) {
    case .added:
      slots[project.commonDirectory] = makeAvailableSlot(for: project)
    case .alreadyRegistered:
      // 起動時に到達できなかった Project を同じ repository として選び直したなら、確かめ直す。
      // 一覧の `directory` は既存のものを保つので、到達可能性もそちらで判定する。
      if case .unavailable = slots[project.commonDirectory],
        let existing = registry.project(project.commonDirectory)
      {
        let slot = await makeSlot(for: existing)
        // await の間に同じ Project の追加が先に終わっていたり、登録解除されていたりする。
        // まだ到達不能のときだけ差し替え、そうでなければ作ったモデルを止めて捨てる —
        // 残すと同じ Project の AppModel が2つ rescan を回す。
        if case .unavailable = slots[project.commonDirectory] {
          slots[project.commonDirectory] = slot
        } else if case .available(let model) = slot {
          model.stop()
        }
      }
    }
    registry.reselect(selectable: isSelectable)
    save()
  }

  func select(_ commonDirectory: WorktreeIdentity) {
    guard isSelectable(commonDirectory) else { return }
    registry.select(commonDirectory)
    save()
  }

  /// 一覧から外すだけで、repository・tmux session・アプリ内データには触れない (設計書 §16.1)。
  /// その Project の端末は view ごと破棄され、tmux client が detach する。
  func unregister(_ commonDirectory: WorktreeIdentity) {
    if case .available(let model) = slots[commonDirectory] {
      model.stop()
    }
    slots[commonDirectory] = nil
    registry.unregister(commonDirectory)
    registry.reselect(selectable: isSelectable)
    save()
  }

  /// 確認に出す session と保存データを済ませてからダイアログを出す。結果が揃う前に出すと、
  /// 本文に載せる session 一覧が確認後に変わる。
  func requestUnregister(_ commonDirectory: WorktreeIdentity) async {
    guard let project = registry.project(commonDirectory) else { return }
    let review = await makeUnregisterReview(for: project)
    guard registry.project(commonDirectory) != nil else { return }
    pendingUnregister = review
  }

  func dismissUnregister() {
    pendingUnregister = nil
  }

  /// 順序には理由がある。`AppModel` の保存を待たないと、遅れて着いた保存が消したはずの
  /// `projects/<hash>/` を作り直す。session を kill する前に一覧から外すのは、表示中の端末が
  /// 終了表示になったり再 attach を試みたりしないため。
  func unregisterAndDelete(_ review: ProjectUnregisterReview) async {
    let commonDirectory = review.project.commonDirectory
    if case .available(let model) = slots[commonDirectory] {
      // stop() 後は保存が積まれない (`canSave`) ので、待つのは既に積まれた分だけで足りる。
      model.stop()
      await model.pendingSave?.value
    }
    unregister(commonDirectory)

    var problems = await kill(review.sessions)
    if review.inventoryLoadFailure != nil {
      problems.append("保存データを読めなかったため、アプリ内データは残しています。")
    } else if let store = review.store {
      problems.append(contentsOf: await remove(store))
    }

    if !problems.isEmpty {
      warning =
        "「\(review.project.displayName)」の登録は解除しましたが、削除しきれていません。"
        + problems.joined(separator: " ")
    }
  }

  /// socket 欠落は、取り残された server が居ないと確認できたときだけ成功とする。居る場合と
  /// 確認できない場合は、session を終了できていないので問題として返す (Issue #500)。
  private func kill(_ sessions: [TmuxSessionName]) async -> [String] {
    guard let runner = dependencies.tmuxRunner else { return [] }
    let operations = TmuxSessionOperations(runner: runner)
    var problems: [String] = []
    for session in sessions {
      do {
        try await operations.kill(session: session)
      } catch {
        switch error {
        case .sessionNotFound, .serverNotRunning: break
        case .serverSocketMissing(let socketPath):
          let result = await TmuxOrphanedServerProbe().probe(socketPath: socketPath)
          if result != .absent {
            problems.append(
              "tmux session「\(session.rawValue)」を終了できませんでした: "
                + result.orphanedServerExplanation(socketPath: socketPath))
          }
        default: problems.append("tmux session「\(session.rawValue)」を終了できませんでした: \(error)")
        }
      }
    }
    return problems
  }

  private func remove(_ store: WorktreeInventoryStore) async -> [String] {
    do {
      guard let kept = try await store.remove().keptDirectory else { return [] }
      let entries = kept.entries.joined(separator: ", ")
      return ["保存データのディレクトリに他のファイルが残っています: \(kept.path) (\(entries))"]
    } catch {
      return ["保存データを削除できませんでした: \(error)"]
    }
  }

  func dismissWarning() {
    warning = nil
  }

  func showWarning(_ text: String) {
    warning = text
  }

  private func makeUnregisterReview(
    for project: RegisteredProject
  ) async
    -> ProjectUnregisterReview
  {
    var existing: [String] = []
    var listingFailure: String?
    if let runner = dependencies.tmuxRunner {
      do {
        existing = try await TmuxSessionOperations(runner: runner).list()
      } catch .serverSocketMissing(let socketPath) {
        let result = await TmuxOrphanedServerProbe().probe(socketPath: socketPath)
        if result != .absent {
          listingFailure = result.orphanedServerExplanation(socketPath: socketPath)
        }
      } catch {
        listingFailure = "\(error)"
      }
    } else {
      listingFailure = "tmux を使えない起動です"
    }

    let store = dependencies.applicationSupportDirectory.map {
      WorktreeInventoryStore(
        fileURL: WorktreeInventoryStore.defaultFileURL(
          applicationSupportDirectory: $0, projectRootIdentity: project.commonDirectory))
    }
    var saved: PersistedWorktreeInventory?
    var loadFailure: String?
    if let store {
      do {
        saved = try await store.load()
      } catch {
        loadFailure = "\(error)"
      }
    }

    var observed: [WorktreeIdentity] = []
    if case .available(let model) = slots[project.commonDirectory] {
      observed =
        (model.inventory.projectRoot.map { [$0.identity] } ?? [])
        + model.inventory.taskWorktrees.map(\.identity)
    }

    let sessions =
      listingFailure == nil
      ? ProjectSessionCleanup.sessions(
        projectCommonDirectory: project.commonDirectory, saved: saved, observed: observed,
        existingSessionNames: existing)
      : []
    return ProjectUnregisterReview(
      project: project, sessions: sessions, sessionListingFailure: listingFailure,
      inventoryLoadFailure: loadFailure, store: store)
  }

  private func isSelectable(_ commonDirectory: WorktreeIdentity) -> Bool {
    if case .available = slots[commonDirectory] { return true }
    return false
  }

  private func makeSlot(for project: RegisteredProject) async -> ProjectSlot {
    switch await resolver.availability(of: project) {
    case .available: makeAvailableSlot(for: project)
    case .unavailable(let reason): .unavailable(Self.describe(reason))
    }
  }

  private func makeAvailableSlot(for project: RegisteredProject) -> ProjectSlot {
    let model = AppModel(project: project, dependencies: dependencies, notifier: notifier)
    model.run()
    return .available(model)
  }

  private func save() {
    guard canSave, let store else { return }
    let snapshot = PersistedProjectRegistry(registry)
    // 直前の保存を待ってから書く (`AppModel.save()` と同じ理由)。
    let previous = pendingSave
    pendingSave = Task {
      await previous?.value
      do {
        try await store.save(snapshot)
      } catch {
        warning = "Project の一覧を保存できませんでした: \(error)"
      }
    }
  }

  private static func describe(_ reason: ProjectUnavailability) -> String {
    switch reason {
    case .unresolvable(let error): describe(error)
    case .replaced(let other): "別の repository を指しています (\(other.rawValue))"
    }
  }

  /// git の生の出力はメニューに載せきれないので1行に丸める。原文は `NSLog` に残す。
  private static func describe(_ error: GitProjectResolutionError) -> String {
    NSLog("[app] Project を解決できません: \(String(describing: error))")
    return switch error {
    case .directoryUnreachable: "ディレクトリへ到達できません"
    case .notARepository(_, .commandFailed(_, _, let stderr)):
      "Git repository として開けません: "
        + (stderr.split(separator: "\n").first.map(String.init) ?? "")
    case .notARepository: "Git repository として開けません"
    case .git(.binaryNotFound): "git が見つかりません"
    case .git: "git を実行できません"
    case .worktreeList, .malformedWorktreeList, .emptyWorktreeList,
      .unexpectedCommonDirectoryOutput:
      "git の出力を解釈できません"
    }
  }
}

extension RegisteredProject {
  /// 一覧の表示名。bare repository では `repo.git` のように bare ディレクトリ名になる。
  var displayName: String {
    URL(fileURLWithPath: directory).lastPathComponent
  }
}

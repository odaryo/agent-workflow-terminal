/// Terminal に登録された1つの Git repository (設計書 §2.2)。
public struct RegisteredProject: Sendable, Hashable {
  /// Project の同一性。git common dir の絶対パスで、Project Root の安定 ID そのもの (設計書 §3.5)。
  /// 同じ repository を main worktree・linked worktree・サブディレクトリのどこから選んでも同じ値に
  /// なる (git 2.50.1 実測)。
  public let commonDirectory: WorktreeIdentity
  /// worktree 検出の起点。main worktree の作業ツリー、bare repository ではその bare ディレクトリ
  /// (設計書 §2.3)。`git worktree list` が返したパスをそのまま持ち、正規化しない
  /// (`WorktreeIdentity` と同じ理由)。
  public let directory: String

  public init(commonDirectory: WorktreeIdentity, directory: String) {
    self.commonDirectory = commonDirectory
    self.directory = directory
  }
}

public enum ProjectRegistration: Sendable, Equatable {
  case added
  case alreadyRegistered
}

/// 登録済み Project の一覧と、メイン window に表示する1件の選択 (Issue #372)。
///
/// - Important: 到達可能性はここに持たない。パスが消えた等は観測結果であって登録の状態ではなく、
///   一時的に到達できない Project を一覧から落とすと、戻ってきたときに登録し直しになる。
///   選べるかどうかは呼び出し側が `reselect(selectable:)` に渡す。
public struct ProjectRegistry: Sendable, Hashable {
  /// 登録順。
  public private(set) var projects: [RegisteredProject]
  /// 一覧が空でない限り、`unregister` と復元はこれを `nil` のままにしない。`nil` になるのは
  /// 一覧が空のときと、`reselect(selectable:)` が選べる Project を見つけられなかったときだけ。
  public private(set) var selection: WorktreeIdentity?

  public init() {
    projects = []
    selection = nil
  }

  /// 選択が一覧に無ければ先頭、一覧が空なら未選択。同じ common dir が重複していれば先に現れた
  /// ほうだけを残す。
  public init(restoring persisted: PersistedProjectRegistry) {
    self.init()
    for project in persisted.projects {
      append(RegisteredProject(project))
    }
    if let selection = persisted.selection, contains(selection) {
      self.selection = selection
    } else {
      selection = projects.first?.commonDirectory
    }
  }

  public func project(_ commonDirectory: WorktreeIdentity) -> RegisteredProject? {
    projects.first { $0.commonDirectory == commonDirectory }
  }

  /// 追加でも重複でも、その Project を選択する。重複のときは既存の `directory` を保つ。
  @discardableResult
  public mutating func register(_ project: RegisteredProject) -> ProjectRegistration {
    let registration: ProjectRegistration =
      append(project) ? .added : .alreadyRegistered
    selection = project.commonDirectory
    return registration
  }

  /// 一覧から外すだけで、repository と tmux session には触れない (設計書 §16.1)。
  public mutating func unregister(_ commonDirectory: WorktreeIdentity) {
    guard contains(commonDirectory) else { return }
    projects.removeAll { $0.commonDirectory == commonDirectory }
    if selection == commonDirectory {
      selection = projects.first?.commonDirectory
    }
  }

  @discardableResult
  public mutating func select(_ commonDirectory: WorktreeIdentity) -> Bool {
    guard contains(commonDirectory) else { return false }
    selection = commonDirectory
    return true
  }

  /// 選択中の Project を選べないとき、選べる先頭の Project へ移す。1つも無ければ未選択にする。
  public mutating func reselect(selectable: (WorktreeIdentity) -> Bool) {
    if let selection, selectable(selection) { return }
    selection = projects.first { selectable($0.commonDirectory) }?.commonDirectory
  }

  private func contains(_ commonDirectory: WorktreeIdentity) -> Bool {
    project(commonDirectory) != nil
  }

  /// - Returns: 追加したかどうか。
  private mutating func append(_ project: RegisteredProject) -> Bool {
    guard !contains(project.commonDirectory) else { return false }
    projects.append(project)
    return true
  }
}

/// ディスク上の表現。ドメイン型を直接 `Codable` にしないのは `PersistedWorktreeInventory` と同じ理由
/// (フィールド名が保存形式に固定される)。
public struct PersistedProjectRegistry: Sendable, Hashable, Codable {
  public static let currentSchemaVersion = 1

  /// 未知の値を読んだときの扱いは復号側の責務。この型は読んだ値をそのまま持つ。
  public let schemaVersion: Int
  public let projects: [PersistedRegisteredProject]
  public let selection: WorktreeIdentity?

  public init(
    schemaVersion: Int = Self.currentSchemaVersion,
    projects: [PersistedRegisteredProject],
    selection: WorktreeIdentity?
  ) {
    self.schemaVersion = schemaVersion
    self.projects = projects
    self.selection = selection
  }

  public init(_ registry: ProjectRegistry) {
    self.init(
      projects: registry.projects.map(PersistedRegisteredProject.init),
      selection: registry.selection
    )
  }
}

public struct PersistedRegisteredProject: Sendable, Hashable, Codable {
  public let commonDirectory: WorktreeIdentity
  public let directory: String

  public init(commonDirectory: WorktreeIdentity, directory: String) {
    self.commonDirectory = commonDirectory
    self.directory = directory
  }

  public init(_ project: RegisteredProject) {
    self.init(commonDirectory: project.commonDirectory, directory: project.directory)
  }
}

extension RegisteredProject {
  init(_ persisted: PersistedRegisteredProject) {
    self.init(commonDirectory: persisted.commonDirectory, directory: persisted.directory)
  }
}

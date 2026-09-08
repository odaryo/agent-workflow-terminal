/// ディスク上の表現。ドメイン型 (`WorktreeInventory` / `TaskWorktree` / `DetectedWorktree`) を
/// 直接 `Codable` にしない理由は2つある。
///
/// - ドメイン型のフィールド名がそのまま保存形式になり、以後リネームできなくなる。
/// - `TaskWorktree.init` は `isProjectRoot` に `precondition` を持つ。ドメイン型を直接復号すると、
///   壊れた／細工されたファイルがプロセスを落とす。**復号は決してクラッシュしてはならない。**
///
/// Project Root と Task worktree を別のフィールドへ置くことで `isProjectRoot` を保存せずに済ませて
/// いるが、これで守れているのは**保存側**、つまり `init(_:)` が Project Root を Task 側へ書けない
/// ことだけである。読み取り側では、同じ安定 ID が `projectRoot` と `taskWorktrees` の両方に載った
/// ファイルを作れる。それを読んでも復号はクラッシュしないが、§2.3 が禁じる状態そのものを型が
/// 排除しているわけではない。壊れたファイルを読んだときに何が起きるかは
/// `restoreWorktreeInventory(detected:saved:)` 側の規則で決まる。
public struct PersistedWorktreeInventory: Sendable, Hashable, Codable {
  public static let currentSchemaVersion = 1

  /// 未知の値を読んだときの扱いは復号側の責務。この型は読んだ値をそのまま持つ。
  public let schemaVersion: Int
  public let projectRoot: PersistedProjectRootWorktree?
  public let taskWorktrees: [PersistedTaskWorktree]

  public init(
    schemaVersion: Int = Self.currentSchemaVersion,
    projectRoot: PersistedProjectRootWorktree?,
    taskWorktrees: [PersistedTaskWorktree]
  ) {
    self.schemaVersion = schemaVersion
    self.projectRoot = projectRoot
    self.taskWorktrees = taskWorktrees
  }

  public init(_ inventory: WorktreeInventory) {
    self.init(
      projectRoot: inventory.projectRoot.map(PersistedProjectRootWorktree.init),
      taskWorktrees: inventory.taskWorktrees.map(PersistedTaskWorktree.init)
    )
  }
}

/// `isReachable` を持たないのは、到達可能性が観測結果であって保存すべき運用状態ではないため
/// (設計書 §3.2)。復元時の到達可能性は「今回検出できたか」だけで決まる。
public struct PersistedProjectRootWorktree: Sendable, Hashable, Codable {
  public let identity: WorktreeIdentity
  public let worktreePath: String
  public let branch: String?

  public init(identity: WorktreeIdentity, worktreePath: String, branch: String?) {
    self.identity = identity
    self.worktreePath = worktreePath
    self.branch = branch
  }

  init(_ detected: DetectedWorktree) {
    self.init(
      identity: detected.identity,
      worktreePath: detected.worktreePath,
      branch: detected.branch
    )
  }
}

public struct PersistedTaskWorktree: Sendable, Hashable, Codable {
  public let identity: WorktreeIdentity
  public let worktreePath: String
  public let branch: String?
  /// 保存する唯一の運用状態 (設計書 §3.2)。
  public let activation: PersistedWorktreeActivation

  public init(
    identity: WorktreeIdentity,
    worktreePath: String,
    branch: String?,
    activation: PersistedWorktreeActivation
  ) {
    self.identity = identity
    self.worktreePath = worktreePath
    self.branch = branch
    self.activation = activation
  }

  init(_ task: TaskWorktree) {
    self.init(
      identity: task.identity,
      worktreePath: task.detected.worktreePath,
      branch: task.detected.branch,
      activation: PersistedWorktreeActivation(task.activation)
    )
  }
}

/// ドメインの `WorktreeActivation` と別に持つのは、case 名がそのまま保存形式になるのを避けるため。
public enum PersistedWorktreeActivation: String, Sendable, Hashable, Codable {
  case active
  case inactive

  init(_ activation: WorktreeActivation) {
    switch activation {
    case .active: self = .active
    case .inactive: self = .inactive
    }
  }

  var activation: WorktreeActivation {
    switch self {
    case .active: return .active
    case .inactive: return .inactive
    }
  }
}

/// アプリ起動直後の1回目のスキャンに使う (設計書 §3.2、Issue #136)。
///
/// `reconcileDetectedWorktrees` と意味が違う。あちらは観測が途切れていない前提で
/// 「渡されなかった安定 ID は存在しない」と権威的に解釈してよいが、この関数が受け取る `detected` は
/// アプリが止まっていた間の増減を含み、削除と一時的な不可視を区別できない。したがって、
///
/// - 保存に無く今回検出できた worktree は `.inactive` から始める。停止中の出現は §3.2 の
///   「観測中に新しく現れた」に当たらない。
/// - 保存にあり今回検出できなかったものは捨てず、到達不能として保持する。ユーザーの Active 指定を
///   「消えた」と決めつけて捨てないため。ただし今回 entry 単位で観測に失敗したパス (`unobserved`) は
///   `.unreachable` ではなく `.observationFailed` として保持する。到達可能性を確かめられていない
///   ものを「到達不能」と断定して見せないため (Issue #243)。
/// - したがって `appeared` と `disappeared` は常に空になる。復元は出現も消失も宣言しない。
///
/// - Important: `saved` の `nil` は「保存が無い」= 初回起動を表し、空の保存 (前回は1件も
///   無かった) とは区別する。前者は `reconcileDetectedWorktrees(detected:previous: nil)` と
///   同じ結果になる。
/// - Note: 同じ安定 ID の重複と `isProjectRoot` の重複の扱いは `reconcileDetectedWorktrees` と
///   同じで、どちらも最初の1件だけを採る。`saved.taskWorktrees` 側の重複も同様に最初の1件だけを
///   採る。
/// - Note: 同じ安定 ID が `saved.projectRoot` と `saved.taskWorktrees` の両方に載った壊れた
///   ファイルでは、その ID が Project Root として復元されなかった場合に限り Task worktree として
///   復活する。`PersistedWorktreeInventory` はこの入力を型では排除できない (同型の doc 参照)。
///   ここで落とさないのは、復元がユーザーの Active 指定を捨てない側へ倒す関数であるため。
/// - Note: 保存された Project Root の安定 ID が今回まったく検出されず、かつ別の worktree が
///   Project Root として検出された場合、保存側は捨てる。`projectRoot` は1件しか持てず、
///   Project Root を Task 側へ移すことは §2.3 が禁じているため。
public func restoreWorktreeInventory(
  detected: [DetectedWorktree],
  saved: PersistedWorktreeInventory?,
  unobserved: [String] = []
) -> WorktreeScanResult {
  guard let saved else {
    return reconcileDetectedWorktrees(detected: detected, previous: nil, unobserved: unobserved)
  }

  // 検出できているパスは観測できているので、失敗の側を無視する
  // (`reconcileDetectedWorktrees` と同じ規則)。
  let unobservedPaths = Set(unobserved).subtracting(detected.map(\.worktreePath))
  var unobservedIdentities: [WorktreeIdentity] = []

  var savedActivations: [WorktreeIdentity: WorktreeActivation] = [:]
  for task in saved.taskWorktrees where savedActivations[task.identity] == nil {
    savedActivations[task.identity] = task.activation.activation
  }

  var projectRoot: DetectedWorktree?
  var taskWorktrees: [TaskWorktree] = []
  var seen: Set<WorktreeIdentity> = []

  for candidate in detected {
    guard seen.insert(candidate.identity).inserted else { continue }

    guard !candidate.isProjectRoot else {
      if projectRoot == nil {
        projectRoot = candidate
      }
      continue
    }

    taskWorktrees.append(
      TaskWorktree(
        detected: candidate,
        activation: savedActivations[candidate.identity] ?? .inactive
      )
    )
  }

  if let restoredRoot = restoredProjectRoot(
    saved: saved, detectedProjectRoot: projectRoot, seen: seen, unobservedPaths: unobservedPaths)
  {
    projectRoot = restoredRoot
    if restoredRoot.observation == .observationFailed {
      unobservedIdentities.append(restoredRoot.identity)
    }
  }

  var retained = seen
  if let projectRoot {
    retained.insert(projectRoot.identity)
  }
  let leftovers = restoredLeftovers(
    saved: saved, retained: retained, unobservedPaths: unobservedPaths)
  taskWorktrees.append(contentsOf: leftovers.taskWorktrees)
  unobservedIdentities.append(contentsOf: leftovers.unobserved)

  return WorktreeScanResult(
    inventory: WorktreeInventory(projectRoot: projectRoot, taskWorktrees: taskWorktrees),
    appeared: [],
    disappeared: [],
    unobserved: unobservedIdentities
  )
}

/// 今回どれとも突き合わなかった保存済み Task worktree。ユーザーの Active 指定を捨てないため、
/// 検出できていなくても一覧に残す。
private func restoredLeftovers(
  saved: PersistedWorktreeInventory,
  retained: Set<WorktreeIdentity>,
  unobservedPaths: Set<String>
) -> (taskWorktrees: [TaskWorktree], unobserved: [WorktreeIdentity]) {
  var remaining = retained
  var taskWorktrees: [TaskWorktree] = []
  var unobserved: [WorktreeIdentity] = []
  for task in saved.taskWorktrees where remaining.insert(task.identity).inserted {
    let observation = restoredObservation(of: task.worktreePath, in: unobservedPaths)
    if observation == .observationFailed {
      unobserved.append(task.identity)
    }
    taskWorktrees.append(
      TaskWorktree(
        detected: DetectedWorktree(
          identity: task.identity,
          worktreePath: task.worktreePath,
          branch: task.branch,
          isProjectRoot: false,
          observation: observation
        ),
        activation: task.activation.activation
      )
    )
  }
  return (taskWorktrees, unobserved)
}

/// 今回検出できなかった保存済み Project Root を保持する。捨てる条件は
/// `restoreWorktreeInventory` の doc のとおり。
private func restoredProjectRoot(
  saved: PersistedWorktreeInventory,
  detectedProjectRoot: DetectedWorktree?,
  seen: Set<WorktreeIdentity>,
  unobservedPaths: Set<String>
) -> DetectedWorktree? {
  guard let savedProjectRoot = saved.projectRoot, detectedProjectRoot == nil,
    !seen.contains(savedProjectRoot.identity)
  else { return nil }
  return DetectedWorktree(
    identity: savedProjectRoot.identity,
    worktreePath: savedProjectRoot.worktreePath,
    branch: savedProjectRoot.branch,
    isProjectRoot: true,
    observation: restoredObservation(of: savedProjectRoot.worktreePath, in: unobservedPaths)
  )
}

/// 検出できなかった保存済み worktree を、既定の `unreachable` ではなく `observationFailed` に
/// 振り替える。起動直後の1回目で「到達不能」と断定して見せないため — このスキャンでは
/// 到達可能性そのものを確かめられていない。
private func restoredObservation(
  of worktreePath: String,
  in unobservedPaths: Set<String>
) -> WorktreeObservation {
  unobservedPaths.contains(worktreePath) ? .observationFailed : .unreachable
}

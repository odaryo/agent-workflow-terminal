/// git から観測したままの worktree。Active/Inactive は git の状態ではなく Terminal が持つ
/// UI／運用状態 (設計書 §3.2) なので、この型には含めない。
public struct DetectedWorktree: Sendable, Hashable {
  public let identity: WorktreeIdentity
  public let worktreePath: String
  /// detached HEAD では `nil`。
  public let branch: String?
  /// main worktree であること。Project Root は Task worktree と別枠であり (§2.3)、
  /// Active/Inactive の対象にしない。
  public let isProjectRoot: Bool

  public init(
    identity: WorktreeIdentity,
    worktreePath: String,
    branch: String?,
    isProjectRoot: Bool
  ) {
    self.identity = identity
    self.worktreePath = worktreePath
    self.branch = branch
    self.isProjectRoot = isProjectRoot
  }
}

public enum WorktreeActivation: Sendable, Hashable {
  case active
  case inactive
}

public struct TaskWorktree: Sendable, Hashable {
  public let detected: DetectedWorktree
  public let activation: WorktreeActivation

  public var identity: WorktreeIdentity { detected.identity }

  public init(detected: DetectedWorktree, activation: WorktreeActivation) {
    self.detected = detected
    self.activation = activation
  }
}

/// Project Root を `taskWorktrees` と別のフィールドに置くのは、「Project Root が Inactive」
/// という表現できてはいけない状態を型で作らないため (§2.3)。
public struct WorktreeInventory: Sendable, Hashable {
  /// 検出できなかった場合は `nil`。
  public let projectRoot: DetectedWorktree?
  public let taskWorktrees: [TaskWorktree]

  public init(projectRoot: DetectedWorktree?, taskWorktrees: [TaskWorktree]) {
    self.projectRoot = projectRoot
    self.taskWorktrees = taskWorktrees
  }

  func activation(of identity: WorktreeIdentity) -> WorktreeActivation? {
    taskWorktrees.first { $0.identity == identity }?.activation
  }
}

public struct WorktreeScanResult: Sendable, Hashable {
  public let inventory: WorktreeInventory
  /// 観測中に新しく現れ、自動的に Active 化した worktree (§3.2)。初回スキャンでは常に空。
  public let appeared: [WorktreeIdentity]
  /// 前回状態にあって今回検出されなかった worktree。Project Root も対象に含む。
  public let disappeared: [WorktreeIdentity]

  public init(
    inventory: WorktreeInventory,
    appeared: [WorktreeIdentity],
    disappeared: [WorktreeIdentity]
  ) {
    self.inventory = inventory
    self.appeared = appeared
    self.disappeared = disappeared
  }
}

/// 設計書 §3.2 の検出規則。
///
/// - Important: `previous` の `nil` は「前回状態が無い」= 初回スキャンを表し、空の
///   `WorktreeInventory` (前回は1件も無かった) とは区別する。初回スキャンでは検出された
///   Task worktree をすべて `.inactive` から始め、新規出現として数えない。Project 登録時点で
///   既に存在していた過去の worktree が一斉にタブ化する事故を防ぐため。
///   **永続化層がまだ無いため、アプリを再起動すると毎回この初回スキャンになり、
///   前回 Active だった worktree も Inactive へ戻る。**
/// - Note: 同じ安定 ID が複数回渡された場合は最初の1件だけを採る。git の一覧出力の順序が
///   安定であることに合わせ、結果を決定的にするための規則であり、後勝ちにする理由が無い。
///   `isProjectRoot` が複数あった場合も最初の1件だけを Project Root とし、残りは捨てる
///   (Task worktree へ格下げすると §2.3 が禁じる状態を作ってしまうため)。
/// - Note: 前回 Project Root だった安定 ID が Task worktree として現れた場合は、既知の ID
///   なので新規出現とせず `.inactive` から始める。自動 Active 化の対象は「観測中に新しく
///   現れた worktree」に限るため。
public func reconcileDetectedWorktrees(
  detected: [DetectedWorktree],
  previous: WorktreeInventory?
) -> WorktreeScanResult {
  var projectRoot: DetectedWorktree?
  var taskWorktrees: [TaskWorktree] = []
  var appeared: [WorktreeIdentity] = []
  var seen: Set<WorktreeIdentity> = []

  for candidate in detected {
    guard seen.insert(candidate.identity).inserted else { continue }

    guard !candidate.isProjectRoot else {
      if projectRoot == nil {
        projectRoot = candidate
      }
      continue
    }

    let activation: WorktreeActivation
    if let previous {
      if let previousActivation = previous.activation(of: candidate.identity) {
        activation = previousActivation
      } else if previous.projectRoot?.identity == candidate.identity {
        activation = .inactive
      } else {
        activation = .active
        appeared.append(candidate.identity)
      }
    } else {
      activation = .inactive
    }

    taskWorktrees.append(TaskWorktree(detected: candidate, activation: activation))
  }

  var disappeared: [WorktreeIdentity] = []
  if let previous {
    var retained = Set(taskWorktrees.map(\.identity))
    if let projectRoot {
      retained.insert(projectRoot.identity)
    }

    var previousIdentities: [WorktreeIdentity] = []
    if let previousProjectRoot = previous.projectRoot {
      previousIdentities.append(previousProjectRoot.identity)
    }
    previousIdentities.append(contentsOf: previous.taskWorktrees.map(\.identity))

    disappeared = previousIdentities.filter { !retained.contains($0) }
  }

  return WorktreeScanResult(
    inventory: WorktreeInventory(projectRoot: projectRoot, taskWorktrees: taskWorktrees),
    appeared: appeared,
    disappeared: disappeared
  )
}

/// 作業ツリーの観測結果 (設計書 §3.2)。
///
/// - Important: `unreachable` と `observationFailed` を1つの `false` に潰さない。前者は
///   「作業ツリーへ到達できないと**確かめられた**」観測結果で、admin ディレクトリ側から安定 ID を
///   引けている。後者は観測そのものが失敗した状態で、到達可能性も安定 ID も分かっていない
///   (git の timeout や EACCES がここへ入る)。潰すと「観測できなかった」と「消えた」の区別が
///   上位で失われ、同じ worktree が新規出現として扱われて Active 指定が Inactive へ落ちる
///   (設計書 §3.2)。
public enum WorktreeObservation: Sendable, Hashable {
  case reachable
  case unreachable
  case observationFailed
}

/// git から観測したままの worktree。Active/Inactive は git の状態ではなく Terminal が持つ
/// UI／運用状態 (設計書 §3.2) なので、この型には含めない。
public struct DetectedWorktree: Sendable, Hashable {
  public let identity: WorktreeIdentity
  /// `identity` と違い絶対パスであることを検証しない。値の出どころは
  /// `git worktree list --porcelain` であり、壊れた出力で初期化を失敗させると、
  /// 1件の異常で一覧全体を失う。部分成功として扱う責務はパーサ側にある
  /// (docs/coding-guidelines.md §2.3)。この型では表示用の文字列として素通しする。
  public let worktreePath: String
  /// detached HEAD では `nil`。
  public let branch: String?
  /// main worktree であること。Project Root は Task worktree と別枠であり (§2.3)、
  /// Active/Inactive の対象にしない。
  public let isProjectRoot: Bool
  /// `reachable` でない間も安定 ID と Active/Inactive は保持する (設計書 §3.2)。
  ///
  /// - Important: `unreachable` は「作業ツリーが実在しない」ことの証明ではない。観測側の判定は
  ///   作業ツリーのパスの metadata 読み取りに依存しており、macOS 26.5 実測では MAC ポリシーが
  ///   metadata の読み取りだけを拒否すると、`access(X_OK)` と `chdir` は成功する実在の worktree
  ///   でも `fileExists` が `false` になり、git も exit 128 になる。
  public let observation: WorktreeObservation

  /// `observationFailed` を利用できる側へ倒さない。観測できていない worktree の Active 化と
  /// tmux attach は、`unreachable` と同じ理由 (attach 先を確かめられていない) で認めない。
  public var isReachable: Bool { observation == .reachable }

  public init(
    identity: WorktreeIdentity,
    worktreePath: String,
    branch: String?,
    isProjectRoot: Bool,
    isReachable: Bool = true
  ) {
    self.init(
      identity: identity,
      worktreePath: worktreePath,
      branch: branch,
      isProjectRoot: isProjectRoot,
      observation: isReachable ? .reachable : .unreachable
    )
  }

  public init(
    identity: WorktreeIdentity,
    worktreePath: String,
    branch: String?,
    isProjectRoot: Bool,
    observation: WorktreeObservation
  ) {
    self.identity = identity
    self.worktreePath = worktreePath
    self.branch = branch
    self.isProjectRoot = isProjectRoot
    self.observation = observation
  }

  func observing(_ observation: WorktreeObservation) -> Self {
    Self(
      identity: identity,
      worktreePath: worktreePath,
      branch: branch,
      isProjectRoot: isProjectRoot,
      observation: observation
    )
  }
}

public enum WorktreeActivation: Sendable, Hashable {
  case active
  case inactive
}

/// 配列の順を開いた順の記録に使うため、Active にすると末尾へ移す (設計書 §13)。
/// Active でなくしても位置は変えない。
public func applyingActivation(
  _ activation: WorktreeActivation,
  of identity: WorktreeIdentity,
  to worktrees: [TaskWorktree]
) -> [TaskWorktree] {
  guard let index = worktrees.firstIndex(where: { $0.identity == identity }),
    worktrees[index].activation != activation
  else { return worktrees }

  var updated = worktrees
  let task = TaskWorktree(detected: worktrees[index].detected, activation: activation)
  if activation == .active {
    updated.remove(at: index)
    updated.append(task)
  } else {
    updated[index] = task
  }
  return updated
}

public struct TaskWorktree: Sendable, Hashable {
  public let detected: DetectedWorktree
  public let activation: WorktreeActivation

  public var identity: WorktreeIdentity { detected.identity }

  /// Project Root に Active/Inactive を持たせるのは §2.3 に反する状態なので、`isProjectRoot` が
  /// 立った `detected` を拒否する。`reconcileDetectedWorktrees` は決して渡さないため、これが
  /// 落ちるのは呼び出し側の組み立てが間違っているときだけ。
  public init(detected: DetectedWorktree, activation: WorktreeActivation) {
    precondition(
      !detected.isProjectRoot,
      "Project Root は Task worktree として扱えない (設計書 §2.3)"
    )
    self.detected = detected
    self.activation = activation
  }
}

/// Project Root を `taskWorktrees` と別のフィールドに置くのは、Project Root に Active/Inactive を
/// 持たせる余地を無くすため (§2.3)。フラグの立った `DetectedWorktree` を Task 側へ入れる誤りは
/// 型では防げないので、`TaskWorktree` の初期化子が拒否する。
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
  /// 観測中に新しく現れた時点で到達できた worktree (設計書 §3.2)。初回スキャンでは常に空。
  /// 到達不能のまま現れた worktree は、後で到達できても新規出現には数えない。
  public let appeared: [WorktreeIdentity]
  /// 前回状態にあって今回検出されなかった worktree。Project Root も対象に含む。
  /// 観測に失敗しただけの worktree は含めない (`unobserved`)。
  public let disappeared: [WorktreeIdentity]
  /// 今回の観測に失敗し、前回の値のまま保持した worktree。Project Root も対象に含む。
  /// 消失ではないので `disappeared` と排他であり、UI へ「観測できていない」と出すための一覧でもある。
  public let unobserved: [WorktreeIdentity]

  public init(
    inventory: WorktreeInventory,
    appeared: [WorktreeIdentity],
    disappeared: [WorktreeIdentity],
    unobserved: [WorktreeIdentity] = []
  ) {
    self.inventory = inventory
    self.appeared = appeared
    self.disappeared = disappeared
    self.unobserved = unobserved
  }
}

/// 設計書 §3.2 の検出規則。
///
/// - Important: `isListingComplete` が `true` のとき、`detected` は**そのスキャン時点の完全な一覧**
///   でなければならない。「渡されなかった安定 ID は存在しない」と権威的に解釈するため、部分的な
///   結果を渡すと、その回で未検出 worktree が `disappeared` になり、次の回で
///   ユーザーの Active/Inactive 指定を失い、新規出現として `.inactive` から始めてしまう。
///   これは設計書 §3.2 の「worktreeが消えた」と「今回は観測できなかった」を区別する規則に反する。
///   部分的な結果を渡すときは `isListingComplete: false` を指定する。全体のスキャンが失敗した
///   ときは、空の一覧を渡すのではなく、この関数を呼ばずに前回状態を保つ。
/// - Important: entry 単位で観測に失敗した作業ツリーのパスは `unobserved` へ渡す。これが
///   完全な一覧でも「渡されなかった安定 ID は存在しない」という権威的な解釈の例外で、渡さないと
///   1回の観測失敗がそのまま消失になり、上の事故がそのまま起きる (Issue #243)。安定 ID ではなく
///   作業ツリーのパスで渡すのは、観測に失敗した entry からは安定 ID を引けていないためである。
///   `detected` にも載っているパスは検出できているので `unobserved` 側を無視する。
///   `previous` のどれとも一致しないパスは保持しようが無いので何もしない (UI への通知は
///   呼び出し側の責務)。
/// - Note: git の検出順は開いた順を表さないため、観測失敗として保持したものも前回の位置を
///   維持する (設計書 §13)。前回状態が無い場合と新規の worktree 同士だけは検出順を使う。
/// - Important: `previous` の `nil` は「前回状態が無い」= 初回スキャンを表し、空の
///   `WorktreeInventory` (前回は1件も無かった) とは区別する。初回スキャンでは検出された
///   Task worktree をすべて `.inactive` から始め、新規出現として数えない。
///   初回から到達不能な Task worktree も `.inactive` で保持する。安定 ID は観測できているため一覧から
///   捨てる理由はなく、利用できないタブを Active にする理由もない。
/// - Important: **アプリ再起動後の1回目のスキャンにこの関数を使わない。** 保存された状態があるなら
///   `restoreWorktreeInventory(detected:saved:)` を使う。「渡されなかった安定 ID は存在しない」という
///   解釈が権威的なのは観測が途切れていない間だけで、アプリが止まっていた間の増減には成り立たない
///   (削除と一時的な不可視を区別できない)。保存を `previous` として渡すと、停止中に消えていた
///   worktree が `disappeared` になり、ユーザーの Active/Inactive 指定を失う。
/// - Note: 同じ安定 ID が複数回渡された場合は最初の1件だけを採る。git の一覧出力の順序が
///   安定であることに合わせ、結果を決定的にするための規則であり、後勝ちにする理由が無い。
///   `isProjectRoot` が複数あった場合も最初の1件だけを Project Root とし、残りは捨てる
///   (Task worktree へ格下げすると §2.3 が禁じる状態を作ってしまうため)。
/// - Note: 前回 Project Root だった安定 ID が Task worktree として現れた場合は、既知の ID
///   なので新規出現とせず `.inactive` から始める。Project Root は Active/Inactive を持たず
///   (§2.3)、引き継ぐ指定が無いため。
public func reconcileDetectedWorktrees(
  detected: [DetectedWorktree],
  previous: WorktreeInventory?,
  unobserved: [String] = [],
  isListingComplete: Bool = true
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

    let initial = initialActivation(of: candidate, previous: previous)
    if initial.isNewlyAppeared {
      appeared.append(candidate.identity)
    }
    taskWorktrees.append(TaskWorktree(detected: candidate, activation: initial.activation))
  }

  var disappeared: [WorktreeIdentity] = []
  var unobservedIdentities: [WorktreeIdentity] = []
  if let previous {
    let unobservedPaths = Set(unobserved).subtracting(detected.map(\.worktreePath))

    if let retainedRoot = retainedProjectRoot(
      previous: previous, detectedProjectRoot: projectRoot, seen: seen,
      unobservedPaths: unobservedPaths, isListingComplete: isListingComplete)
    {
      projectRoot = retainedRoot
      unobservedIdentities.append(retainedRoot.identity)
    }

    for task in previous.taskWorktrees
    where !seen.contains(task.identity)
      && (!isListingComplete || unobservedPaths.contains(task.detected.worktreePath))
    {
      seen.insert(task.identity)
      // 不完全な一覧で未検出の worktree を observationFailed にすると、一過性の一覧取得失敗で
      // 表示中の session の選択が外れるため、個別の観測失敗とは区別して前回の状態を残す。
      taskWorktrees.append(
        TaskWorktree(
          detected: isListingComplete ? task.detected.observing(.observationFailed) : task.detected,
          activation: task.activation
        ))
      unobservedIdentities.append(task.identity)
    }

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
    taskWorktrees = taskWorktreesInOpenedOrder(
      taskWorktrees, previousIdentities: previous.taskWorktrees.map(\.identity))
  }

  return WorktreeScanResult(
    inventory: WorktreeInventory(projectRoot: projectRoot, taskWorktrees: taskWorktrees),
    appeared: appeared,
    disappeared: disappeared,
    unobserved: unobservedIdentities
  )
}

func taskWorktreesInOpenedOrder(
  _ worktrees: [TaskWorktree],
  previousIdentities: [WorktreeIdentity]
) -> [TaskWorktree] {
  var remaining = Dictionary(uniqueKeysWithValues: worktrees.map { ($0.identity, $0) })
  let previous = previousIdentities.compactMap { remaining.removeValue(forKey: $0) }
  return previous + worktrees.filter { remaining[$0.identity] != nil }
}

/// 観測に失敗した Project Root を前回の値のまま保持する。保持できるのは今回どれも Project Root
/// として検出されなかったときだけで、`projectRoot` は1件しか持てず、Task 側へ移すことは §2.3 が
/// 禁じているためである。
private func retainedProjectRoot(
  previous: WorktreeInventory,
  detectedProjectRoot: DetectedWorktree?,
  seen: Set<WorktreeIdentity>,
  unobservedPaths: Set<String>,
  isListingComplete: Bool
) -> DetectedWorktree? {
  guard let previousProjectRoot = previous.projectRoot, detectedProjectRoot == nil,
    !seen.contains(previousProjectRoot.identity),
    !isListingComplete || unobservedPaths.contains(previousProjectRoot.worktreePath)
  else { return nil }
  return isListingComplete ? previousProjectRoot.observing(.observationFailed) : previousProjectRoot
}

/// 新規出現した worktree の初期 activation は Inactive とする (設計書 §3.2)。
/// Active 化は人の操作に限り、既知の identity の指定は保持する。
/// 新規出現として数えるのは現れた時点で到達できたものだけで、到達不能からの復帰は数えない。
private func initialActivation(
  of candidate: DetectedWorktree,
  previous: WorktreeInventory?
) -> (activation: WorktreeActivation, isNewlyAppeared: Bool) {
  guard let previous else { return (.inactive, false) }
  if let previousActivation = previous.activation(of: candidate.identity) {
    return (previousActivation, false)
  }
  if previous.projectRoot?.identity == candidate.identity {
    return (.inactive, false)
  }
  return (.inactive, candidate.isReachable)
}

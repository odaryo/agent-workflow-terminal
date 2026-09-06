import Adapters
import Foundation
import TerminalCore
import Testing

/// tmux を使わないので `AWT_TMUX_INTEGRATION` とは別のゲートにする。既定は無効で、
/// CI (`swift test` を素で実行) では走らない。実 CLI に触るテストは環境依存で壊れるため
/// opt-in へ隔離するという既存方針 (docs/coding-guidelines.md §3.2 / §5.3) に合わせている。
private let isGitIntegrationEnabled =
  ProcessInfo.processInfo.environment["AWT_GIT_INTEGRATION"] == "1"

@Suite(
  "隔離 repository からの worktree 検出 (設計書 §3.2 / §3.5)",
  .enabled(if: isGitIntegrationEnabled)
)
struct GitWorktreeDetectorIntegrationTests {

  @Test("linked worktree の安定 ID は <common>/worktrees/<name> になり、Project Root は1件だけ")
  func detectsProjectRootAndLinkedWorktrees() async throws {
    try await withGitRepository { repository in
      try await repository.git(["worktree", "add", "-q", "-b", "wt-feat", "../wt-feat"])

      let result = try await repository.detector().scan()

      let detected = result.detected
      #expect(result.failures.isEmpty)
      #expect(detected.count == 2)
      #expect(detected.filter(\.isProjectRoot).count == 1)
      let root = try #require(detected.first { $0.isProjectRoot })
      let linked = try #require(detected.first { !$0.isProjectRoot })
      #expect(root.identity.rawValue == "\(repository.mainWorktree.path)/.git")
      #expect(
        linked.identity.rawValue == "\(repository.mainWorktree.path)/.git/worktrees/wt-feat")
      #expect(linked.worktreePath == "\(repository.root.path)/wt-feat")
      #expect(linked.branch == "wt-feat")
    }
  }

  @Test("branch を切り替えても安定 ID は変わらない")
  func stableIdentitySurvivesBranchSwitch() async throws {
    try await withGitRepository { repository in
      try await repository.git(["worktree", "add", "-q", "-b", "wt-feat", "../wt-feat"])
      let before = try await repository.detector().scan().detected

      try await repository.git(["checkout", "-q", "-b", "feat2"], in: "wt-feat")
      let after = try await repository.detector().scan().detected

      #expect(before.map(\.identity) == after.map(\.identity))
      #expect(after.first { !$0.isProjectRoot }?.branch == "feat2")
    }
  }

  @Test("git worktree move の後も安定 ID は変わらない")
  func stableIdentitySurvivesWorktreeMove() async throws {
    try await withGitRepository { repository in
      try await repository.git(["worktree", "add", "-q", "-b", "wt-feat", "../wt-feat"])
      let before = try await repository.detector().scan().detected

      try await repository.git(
        ["worktree", "move", "\(repository.root.path)/wt-feat", "\(repository.root.path)/wt-moved"])
      let after = try await repository.detector().scan().detected

      #expect(before.map(\.identity) == after.map(\.identity))
      let moved = try #require(after.first { !$0.isProjectRoot })
      #expect(moved.worktreePath == "\(repository.root.path)/wt-moved")
      // 管理ディレクトリ名は作成時のままで、作業ツリー名とはずれる (設計書 §3.5)。
      #expect(moved.identity.rawValue.hasSuffix("/worktrees/wt-feat"))
    }
  }

  @Test("作業ツリーを消した worktree は検出結果に現れず、スキャンも失敗しない")
  func prunableWorktreeIsSkippedWithoutFailingTheScan() async throws {
    try await withGitRepository { repository in
      try await repository.git(["worktree", "add", "-q", "-b", "wt-gone", "../wt-gone"])
      try FileManager.default.removeItem(at: repository.root.appending(path: "wt-gone"))

      let result = try await repository.detector().scan()

      #expect(result.detected.map(\.isProjectRoot) == [true])
      #expect(result.detected.allSatisfy { !$0.worktreePath.hasSuffix("/wt-gone") })
      #expect(result.failures.isEmpty)
    }
  }

  /// git は `locked` な worktree に `prunable` を付けない (git 2.50.1 実測)。可搬ボリューム上の
  /// worktree を lock するのは `git worktree --help` が勧める運用なので、ここで失敗させると
  /// lock を外すまで Project Root を含む全 worktree が検出できなくなる。
  ///
  /// 公開 init が使う到達可能性の述語を、注入で置き換えずに通す3経路のうちの1つ (消失)。
  @Test("locked な worktree の作業ツリーが消えても、admin 側の安定 ID で到達不能として検出する")
  func lockedWorktreeWithMissingWorkingTreeIsDetectedAsUnreachable() async throws {
    try await withGitRepository { repository in
      try await repository.git(["worktree", "add", "-q", "-b", "wt-keep", "../wt-keep"])
      try await repository.git(["worktree", "add", "-q", "-b", "wt-lock", "../wt-lock"])
      try await repository.git(
        ["worktree", "lock", "\(repository.root.path)/wt-lock", "--reason", "removable volume"])
      try FileManager.default.removeItem(at: repository.root.appending(path: "wt-lock"))

      let result = try await repository.detector().scan()

      #expect(
        result.detected.map(\.worktreePath) == [
          repository.mainWorktree.path,
          "\(repository.root.path)/wt-keep",
          "\(repository.root.path)/wt-lock",
        ])
      let locked = try #require(result.detected.first { $0.worktreePath.hasSuffix("/wt-lock") })
      #expect(
        locked.identity.utf8Bytes
          == Array("\(repository.mainWorktree.path)/.git/worktrees/wt-lock".utf8))
      #expect(!locked.isReachable)
      #expect(locked.branch == "wt-lock")
      #expect(result.detected.filter(\.isProjectRoot).count == 1)
      #expect(result.failures.isEmpty)
    }
  }

  /// 述語の3経路のうちの1つ (作業ツリーのパスが通常ファイル)。実行ビットを立てるのは、
  /// 立てないと `isExecutableFile` だけで除外されてしまい、「ディレクトリか」を見る判定が
  /// 効いていることを固定できないためである (macOS 26.5 実測)。
  @Test("作業ツリーのパスが通常ファイルに置き換わった entry も到達不能として検出する")
  func regularFileAtWorkingTreePathIsDetectedAsUnreachable() async throws {
    try await withGitRepository { repository in
      try await repository.git(["worktree", "add", "-q", "-b", "wt-keep", "../wt-keep"])
      try await repository.git(["worktree", "add", "-q", "-b", "wt-file", "../wt-file"])
      try await repository.git(
        ["worktree", "lock", "\(repository.root.path)/wt-file", "--reason", "removable volume"])
      let replaced = repository.root.appending(path: "wt-file")
      try FileManager.default.removeItem(at: replaced)
      try Data().write(to: replaced)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: replaced.path)

      let result = try await repository.detector().scan()

      #expect(
        result.detected.map(\.worktreePath) == [
          repository.mainWorktree.path,
          "\(repository.root.path)/wt-file",
          "\(repository.root.path)/wt-keep",
        ])
      let unreachable = try #require(result.detected.first { $0.worktreePath == replaced.path })
      #expect(!unreachable.isReachable)
      #expect(
        unreachable.identity.utf8Bytes
          == Array("\(repository.mainWorktree.path)/.git/worktrees/wt-file".utf8))
      #expect(result.failures.isEmpty)
    }
  }

  /// 述語の3経路のうちの1つ (探索権限が無い)。root で走らせるとパーミッションが効かないため、
  /// この経路は再現しない。
  @Test("作業ツリーを探索できなくなった entry も到達不能として検出する")
  func unsearchableWorkingTreeIsDetectedAsUnreachable() async throws {
    try await withGitRepository { repository in
      try await repository.git(["worktree", "add", "-q", "-b", "wt-keep", "../wt-keep"])
      try await repository.git(["worktree", "add", "-q", "-b", "wt-locked", "../wt-locked"])
      try await repository.git(
        ["worktree", "lock", "\(repository.root.path)/wt-locked", "--reason", "removable volume"])
      let unsearchable = repository.root.appending(path: "wt-locked")
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o000], ofItemAtPath: unsearchable.path)
      // 戻さないと後片付けの削除が Permission denied で失敗し、repository が /private/tmp に残る。
      defer {
        try? FileManager.default.setAttributes(
          [.posixPermissions: 0o755], ofItemAtPath: unsearchable.path)
      }

      let result = try await repository.detector().scan()

      #expect(
        result.detected.map(\.worktreePath) == [
          repository.mainWorktree.path,
          "\(repository.root.path)/wt-keep",
          "\(repository.root.path)/wt-locked",
        ])
      let blocked = try #require(result.detected.first { $0.worktreePath == unsearchable.path })
      #expect(!blocked.isReachable)
      #expect(
        blocked.identity.utf8Bytes
          == Array("\(repository.mainWorktree.path)/.git/worktrees/wt-locked".utf8))
      #expect(result.failures.isEmpty)
    }
  }

  /// 到達不能な間の安定 ID が、到達可能なときに git から得られる ID と**バイト単位で**同一でないと、
  /// 到達不能になった瞬間に消失・復帰した瞬間に新規出現になり、ユーザーが意図した Active/Inactive が
  /// 失われる (Issue #160)。`hasSuffix` では固定できない。
  @Test("到達可能 → 到達不能 → 復帰 の3回で安定 ID がバイト単位で変わらず、消失にも新規出現にもならない")
  func stableIdentityIsUnchangedAcrossAnOutage() async throws {
    try await withGitRepository { repository in
      try await repository.git(["worktree", "add", "-q", "-b", "wt-lock", "../wt-lock"])
      try await repository.git(
        ["worktree", "lock", "\(repository.root.path)/wt-lock", "--reason", "removable volume"])
      let workingTree = repository.root.appending(path: "wt-lock")
      let detached = repository.root.appending(path: "detached-volume")

      let detector = try repository.detector()
      let reachable = try await detector.scan()
      try FileManager.default.moveItem(at: workingTree, to: detached)
      let unreachable = try await detector.scan()
      try FileManager.default.moveItem(at: detached, to: workingTree)
      let recovered = try await detector.scan()

      let expected = Array("\(repository.mainWorktree.path)/.git/worktrees/wt-lock".utf8)
      let scans = [reachable, unreachable, recovered]
      #expect(
        scans.map { $0.detected.map(\.isReachable) } == [
          [true, true], [true, false], [true, true],
        ])
      #expect(
        scans.map { scan in scan.detected.filter { !$0.isProjectRoot }.map(\.identity.utf8Bytes) }
          == Array(repeating: [expected], count: 3))
      #expect(scans.allSatisfy { $0.failures.isEmpty })

      var previous: WorktreeInventory?
      for scan in scans {
        let reconciled = reconcileDetectedWorktrees(detected: scan.detected, previous: previous)
        #expect(reconciled.appeared.isEmpty)
        #expect(reconciled.disappeared.isEmpty)
        #expect(reconciled.inventory.taskWorktrees.map(\.activation) == [.inactive])
        previous = reconciled.inventory
      }
    }
  }

  /// `worktree.useRelativePaths` は可搬 repository のための正規の機能で、この機能が狙っている運用
  /// そのものである。このとき `gitdir` の中身は管理ディレクトリからの相対パスになる
  /// (git 2.50.1 実測: `../../../../wt-lock/.git`) ので、cwd 基準で解決すると照合が必ず外れる。
  @Test("gitdir が相対パスで記録された worktree でも、到達不能時に admin 側の安定 ID を引ける")
  func resolvesRelativeGitdirAgainstTheAdministrativeDirectory() async throws {
    try await withGitRepository { repository in
      try await repository.git(
        ["worktree", "add", "--relative-paths", "-q", "-b", "wt-lock", "../wt-lock"])
      let gitdir = repository.mainWorktree.appending(path: ".git/worktrees/wt-lock/gitdir")
      try #require(String(contentsOf: gitdir, encoding: .utf8).hasPrefix("."))
      try await repository.git(
        ["worktree", "lock", "\(repository.root.path)/wt-lock", "--reason", "removable volume"])
      try FileManager.default.removeItem(at: repository.root.appending(path: "wt-lock"))

      let result = try await repository.detector().scan()

      let locked = try #require(result.detected.first { !$0.isProjectRoot })
      #expect(!locked.isReachable)
      #expect(
        locked.identity.utf8Bytes
          == Array("\(repository.mainWorktree.path)/.git/worktrees/wt-lock".utf8))
      #expect(result.failures.isEmpty)
    }
  }

  /// git は管理ディレクトリ名をサニタイズするので (git 2.50.1 実測: `wt lock` →
  /// `worktrees/wt-lock`)、名前から `<common>/worktrees/<name>` を組み立てる実装はここで壊れる。
  /// 非 ASCII を混ぜているのは、`URL(fileURLWithPath:)` を通すと NFC が NFD へ正規化される一方
  /// git は NFC のまま返すため (macOS 26.5 実測)、ASCII 名だけではバイト単位の同一性を
  /// 固定できないからである。
  @Test(
    "作業ツリー名に空白や非 ASCII があっても、到達不能時の安定 ID は git の返す admin パスと一致する",
    arguments: ["wt lock", "wt-caf\u{00E9}"]
  )
  func stableIdentityMatchesGitForSanitizedAdministrativeNames(name: String) async throws {
    try await withGitRepository { repository in
      let workingTree = repository.root.appending(path: name)
      // branch 名に空白は使えないので detached にする。ここで見たいのは admin 名のサニタイズだけ。
      try await repository.git(["worktree", "add", "-q", "--detach", workingTree.path])
      let reachable = try await repository.detector().scan()
      let before = try #require(reachable.detected.first { !$0.isProjectRoot })

      try await repository.git(
        ["worktree", "lock", workingTree.path, "--reason", "removable volume"])
      try FileManager.default.removeItem(at: workingTree)
      let result = try await repository.detector().scan()

      let after = try #require(result.detected.first { !$0.isProjectRoot })
      #expect(!after.isReachable)
      #expect(after.identity.utf8Bytes == before.identity.utf8Bytes)
      #expect(result.failures.isEmpty)
    }
  }

  /// `git worktree move` は `gitdir` の中身だけを書き換え、管理ディレクトリ名は作成時のまま残す
  /// (git 2.50.1 実測)。名前ではなく `gitdir` の中身で照合していることを、両者がずれた状態で固定する。
  @Test("git worktree move の後に到達不能になっても、移動前と同じ安定 ID で検出する")
  func stableIdentityIsUnchangedWhenAMovedWorktreeBecomesUnreachable() async throws {
    try await withGitRepository { repository in
      try await repository.git(["worktree", "add", "-q", "-b", "wt-feat", "../wt-feat"])
      let before = try await repository.detector().scan()
      let moved = repository.root.appending(path: "wt-moved")
      try await repository.git(
        ["worktree", "move", "\(repository.root.path)/wt-feat", moved.path])
      try await repository.git(["worktree", "lock", moved.path, "--reason", "removable volume"])
      try FileManager.default.removeItem(at: moved)

      let result = try await repository.detector().scan()

      let after = try #require(result.detected.first { !$0.isProjectRoot })
      #expect(after.worktreePath == moved.path)
      #expect(!after.isReachable)
      #expect(
        after.identity.utf8Bytes
          == Array("\(repository.mainWorktree.path)/.git/worktrees/wt-feat".utf8))
      #expect(after.identity.utf8Bytes == (try #require(before.detected.last).identity.utf8Bytes))
      #expect(result.failures.isEmpty)
    }
  }

  /// 到達不能な entry と組み合わせた形は作れない。その entry には linked worktree が要る一方、
  /// `worktrees` を読めなくすると git 自身が `worktree list` からその entry を落とすためである
  /// (git 2.50.1 実測: 管理ディレクトリを `chmod 000` にしても exit 0 のまま entry だけが消える)。
  @Test("<common>/worktrees が無い repository でも、Project Root だけを失敗なく検出する")
  func scansRepositoryWithoutAnyLinkedWorktree() async throws {
    try await withGitRepository { repository in
      let worktrees = repository.mainWorktree.appending(path: ".git/worktrees")
      #expect(!FileManager.default.fileExists(atPath: worktrees.path))

      let result = try await repository.detector().scan()

      #expect(result.detected.map(\.worktreePath) == [repository.mainWorktree.path])
      #expect(result.detected.map(\.isProjectRoot) == [true])
      #expect(result.failures.isEmpty)
    }
  }

  /// 作業ツリーのパスに改行が含まれると `gitdir` の中身が複数行になり、1行目しか読まないこの実装は
  /// 照合に失敗する。誤った ID を配るよりは安全なのでそれでよい (`administrativeDirectory`)。実 git で
  /// この失敗を起こせる唯一の形でもある — 他の壊し方 (`gitdir` の削除・0 バイト化・`chmod 000`) では
  /// git 自身が `worktree list` から entry を落としてしまう (git 2.50.1 実測)。
  @Test("到達不能な entry の admin ディレクトリを特定できなければ、ID を推測せず失敗として返す")
  func reportsMissingAdministrativeDirectoryForUnreachableWorkingTree() async throws {
    try await withGitRepository { repository in
      let workingTree = repository.root.appending(path: "wt\nnl")
      try await repository.git(["worktree", "add", "-q", "-b", "wt-nl", workingTree.path])
      try await repository.git(
        ["worktree", "lock", workingTree.path, "--reason", "removable volume"])
      try FileManager.default.removeItem(at: workingTree)

      let result = try await repository.detector().scan()

      #expect(result.detected.map(\.worktreePath) == [repository.mainWorktree.path])
      #expect(result.failures.map(\.worktreePath) == [workingTree.path])
      #expect(result.failures.map(\.reason) == [.administrativeDirectoryNotFound])
    }
  }

  /// 0 バイトの `.git` ファイルには `prunable` が付かず、作業ツリーへは到達できるのに
  /// `rev-parse` が exit 128 になる (git 2.50.1 実測: `fatal: invalid gitfile format`)。
  /// 中断した書き込みや sync で起こる形なので、ここで throw すると Project 全体の検出が止まる。
  @Test("作業ツリーは開けるのに rev-parse が失敗する worktree は、失敗として返して他は検出する")
  func brokenGitFileIsReportedAsAnEntryFailure() async throws {
    try await withGitRepository { repository in
      try await repository.git(["worktree", "add", "-q", "-b", "wt-keep", "../wt-keep"])
      try await repository.git(["worktree", "add", "-q", "-b", "wt-broken", "../wt-broken"])
      let broken = repository.root.appending(path: "wt-broken")
      try Data().write(to: broken.appending(path: ".git"))

      let result = try await repository.detector().scan()

      #expect(
        result.detected.map(\.worktreePath)
          == [repository.mainWorktree.path, "\(repository.root.path)/wt-keep"])
      #expect(result.failures.map(\.worktreePath) == [broken.path])
      let failure = try #require(result.failures.first)
      guard case .gitDirectory(.commandFailed(let exitCode, _, let stderr)) = failure.reason else {
        Issue.record("想定と違う失敗の種類: \(failure)")
        return
      }
      // git のメッセージ本文は版と locale で変わるので、原文を保持していることだけを見る。
      #expect(exitCode == 128)
      #expect(!stderr.isEmpty)
    }
  }

  /// 同じリムーバブルボリューム上に worktree を複数置けば entry 失敗は同時に複数立つ。1件でも
  /// 捨てると、捨てた worktree は上位から消失と区別できなくなる (Issue #137)。`worktree list` は
  /// main worktree の次を作業ツリーのパス昇順で吐く (`fspathcmp`。大小の扱いは
  /// `core.ignoreCase` 依存。git 2.50.1 実測)。期待値はこの git の出力順に依存するが、作成順を
  /// 逆にしてあるので作成順を保つ実装では通らない。
  @Test("同じスキャンで2件の entry が失敗しても、両方を検出順で返す")
  func reportsEveryEntryFailureFromOneScan() async throws {
    try await withGitRepository { repository in
      for name in ["wt-keep", "wt-broken-b", "wt-broken-a"] {
        try await repository.git(["worktree", "add", "-q", "-b", name, "../\(name)"])
      }
      let broken = ["wt-broken-a", "wt-broken-b"].map { repository.root.appending(path: $0) }
      for worktree in broken {
        try Data().write(to: worktree.appending(path: ".git"))
      }

      let result = try await repository.detector().scan()

      #expect(
        result.detected.map(\.worktreePath)
          == [repository.mainWorktree.path, "\(repository.root.path)/wt-keep"])
      #expect(result.failures.map(\.worktreePath) == broken.map(\.path))
    }
  }

  /// 置き換わった先でも `rev-parse` は exit 0 で、その repository の git ディレクトリを返す
  /// (git 2.50.1 実測)。`worktree list` も `prunable` を付けないので、common dir を確かめないと
  /// 無関係な repository の `.git` が安定 ID として通り、Project Root が2件になる。
  @Test("別 repository に置き換わった worktree は検出結果に含めない")
  func worktreeReplacedByAnotherRepositoryIsExcluded() async throws {
    try await withGitRepository { repository in
      try await repository.git(["worktree", "add", "-q", "-b", "wt-swap", "../wt-swap"])
      let swapped = repository.root.appending(path: "wt-swap")
      try FileManager.default.removeItem(at: swapped)
      try FileManager.default.createDirectory(at: swapped, withIntermediateDirectories: true)
      try await repository.git(["init", "-q", "-b", "other"], in: "wt-swap")

      let result = try await repository.detector().scan()

      #expect(result.detected.map(\.worktreePath) == [repository.mainWorktree.path])
      #expect(result.detected.map(\.isProjectRoot) == [true])
      #expect(result.failures.isEmpty)
    }
  }

  @Test("detached HEAD の worktree では branch が nil になる")
  func detachedWorktreeHasNoBranch() async throws {
    try await withGitRepository { repository in
      try await repository.git(["worktree", "add", "-q", "--detach", "../wt-detached"])

      let detected = try await repository.detector().scan().detected

      let detached = try #require(detected.first { !$0.isProjectRoot })
      #expect(detached.branch == nil)
      #expect(detached.worktreePath == "\(repository.root.path)/wt-detached")
    }
  }
}

import Foundation
import TerminalCore
import Testing

@testable import Adapters

/// §9.1.1 の分岐元を実 git で固定する。reflog の記録と `rev-parse` の解決は git の版で変わりうる
/// ので、前提にした記録は `#require` で確かめてから判定する (計測は git 2.54.0、CI は 2.56.0)。
@Suite("§9.1.1 実 git での分岐元")
struct DiffForkPointIntegrationTests {
  // 記録は生のまま残り (`@{-1}` / `@`)、解決は今の文脈で行われる。`@{-1}` は今の直前の branch、
  // `@` は自分自身になるので、どちらを比較元にしても分岐元ではない。
  @Test(
    "`@{-1}` と `@` から作った branch では分岐元を使わない", .timeLimit(.minutes(1)),
    arguments: [("@{-1}", "refs/heads/main"), ("@", "refs/heads/feature")])
  func ignoresContextualStartPoint(startPoint: String, resolvedNow: String) async throws {
    try await withGitRepository { repository in
      try await repository.git(["branch", "other"])
      try await repository.git(["checkout", "-q", "other"])
      try await repository.git(["checkout", "-q", "main"])
      try await repository.git(["branch", "feature", startPoint])
      try await repository.git(["checkout", "-q", "feature"])
      try await repository.requireOldestReflogSubject(
        "branch: Created from " + startPoint, of: "refs/heads/feature")
      let resolved = try await repository.gitExitCode([
        "rev-parse", "--verify", "--quiet", "--symbolic-full-name", startPoint,
      ])
      try #require(resolved.exitCode == 0)
      try #require(resolved.stdout == resolvedNow + "\n")

      let builder = try DiffSnapshotBuilder(
        worktreeRoot: repository.mainWorktree, processRunner: FoundationProcessRunner())
      #expect(await builder.resolveBaseBranch(userSelection: nil) == .undetermined)
    }
  }

  @Test(
    "reflog が失効した branch では分岐元を使わない", .timeLimit(.minutes(1)),
    arguments: [
      ["reflog", "expire", "--expire=now", "refs/heads/feature"],
      // 作成の項目だけを消す。残る最古の項目は `commit: c1` になる。
      ["reflog", "delete", "refs/heads/feature@{1}"],
    ])
  func ignoresExpiredReflog(expire: [String]) async throws {
    try await withGitRepository { repository in
      try await repository.git(["branch", "local-base"])
      try await repository.git(["checkout", "-q", "-b", "feature", "local-base"])
      try await repository.git(["commit", "-q", "--allow-empty", "-m", "c1"])
      let builder = try DiffSnapshotBuilder(
        worktreeRoot: repository.mainWorktree, processRunner: FoundationProcessRunner())
      #expect(
        await builder.resolveBaseBranch(userSelection: nil)
          == .resolved(branch: .local("local-base"), source: .forkPoint))

      try await repository.git(expire)
      #expect(await builder.resolveBaseBranch(userSelection: nil) == .undetermined)
    }
  }

  @Test("reflog を残さずに作った branch では分岐元を使わない", .timeLimit(.minutes(1)))
  func ignoresBranchWithoutReflog() async throws {
    try await withGitRepository { repository in
      try await repository.git(["branch", "local-base"])
      try await repository.git([
        "-c", "core.logAllRefUpdates=false", "branch", "feature", "local-base",
      ])
      try await repository.git(["checkout", "-q", "feature"])
      let exists = try await repository.gitExitCode(["reflog", "exists", "refs/heads/feature"])
      try #require(exists.exitCode == 1)

      let builder = try DiffSnapshotBuilder(
        worktreeRoot: repository.mainWorktree, processRunner: FoundationProcessRunner())
      #expect(await builder.resolveBaseBranch(userSelection: nil) == .undetermined)
    }
  }

  // 大文字小文字を区別しない volume では、loose ref のファイルが別の綴りでも開けるので、
  // `rev-parse` は一覧に無い綴りの完全名を返す。`pack-refs` の後は解決されなくなるので、前後で
  // 結果が変わらないことも見る (git 2.54.0 で計測)。
  @Test(
    "大文字小文字だけが違う綴りから作った branch では、pack-refs の前後とも分岐元を使わない",
    .timeLimit(.minutes(1)),
    arguments: [("Main", "refs/heads/Main"), ("origin/Main", "refs/remotes/origin/Main")])
  func ignoresCaseVariantStartPoint(startPoint: String, resolvedNow: String) async throws {
    try await withGitRepository { repository in
      try await repository.switchToForkedBranch(from: startPoint, resolvingTo: resolvedNow)
      let refs = try await repository.refNameLines()
      try #require(!refs.contains(Array(resolvedNow.utf8)))

      let builder = try DiffSnapshotBuilder(
        worktreeRoot: repository.mainWorktree, processRunner: FoundationProcessRunner())
      #expect(await builder.resolveBaseBranch(userSelection: nil) == .undetermined)

      try await repository.git(["pack-refs", "--all"])
      #expect(await builder.resolveBaseBranch(userSelection: nil) == .undetermined)
    }
  }

  @Test(
    "一覧に在る綴りから作った branch では、pack-refs の前後とも分岐元を使う", .timeLimit(.minutes(1)),
    arguments: [
      ("main", GitBranchRef.local("main")), ("origin/main", GitBranchRef.remote("origin/main")),
    ])
  func resolvesListedStartPoint(startPoint: String, forkPoint: GitBranchRef) async throws {
    try await withGitRepository { repository in
      try await repository.switchToForkedBranch(from: startPoint, resolvingTo: forkPoint.fullName)
      let refs = try await repository.refNameLines()
      try #require(refs.contains(Array(forkPoint.fullName.utf8)))

      let builder = try DiffSnapshotBuilder(
        worktreeRoot: repository.mainWorktree, processRunner: FoundationProcessRunner())
      #expect(
        await builder.resolveBaseBranch(userSelection: nil)
          == .resolved(branch: forkPoint, source: .forkPoint))

      try await repository.git(["pack-refs", "--all"])
      #expect(
        await builder.resolveBaseBranch(userSelection: nil)
          == .resolved(branch: forkPoint, source: .forkPoint))
    }
  }

  // Swift の `String ==` は正準等価で比べ、NFC と NFD を同じとみなすので、前提はすべて UTF-8 の
  // バイト列で確かめる。NFC の ref を作るときだけ precompose を有効にし、NFD の start-point と
  // 一覧の綴りが異なる前提を git の設定で固定する。
  @Test("正規化だけが違う綴りから作った branch では分岐元を使わない", .timeLimit(.minutes(1)))
  func ignoresNormalizationVariantStartPoint() async throws {
    let composed = "\u{304C}"
    let decomposed = "\u{304B}\u{3099}"
    try await withGitRepository { repository in
      try await repository.git(["config", "core.precomposeunicode", "false"])
      try await repository.git(["-c", "core.precomposeunicode=true", "branch", composed])
      try await repository.git(["switch", "-q", "-c", "x", decomposed])

      let subjects = try await repository.gitExitCode([
        "reflog", "show", "--no-show-signature", "--format=%gs", "refs/heads/x", "--",
      ])
      try #require(subjects.exitCode == 0)
      try #require(
        utf8Lines(subjects.stdout).last == Array(("branch: Created from " + decomposed).utf8))
      let resolved = try await repository.gitExitCode([
        "rev-parse", "--verify", "--quiet", "--symbolic-full-name", decomposed,
      ])
      try #require(resolved.exitCode == 0)
      try #require(Array(resolved.stdout.utf8) == Array(("refs/heads/" + decomposed + "\n").utf8))
      let refs = try await repository.refNameLines()
      try #require(refs.contains(Array(("refs/heads/" + composed).utf8)))
      try #require(!refs.contains(Array(("refs/heads/" + decomposed).utf8)))

      let builder = try DiffSnapshotBuilder(
        worktreeRoot: repository.mainWorktree, processRunner: FoundationProcessRunner())
      #expect(await builder.resolveBaseBranch(userSelection: nil) == .undetermined)
    }
  }

  // `String ==` では NFD の完全名を採っても通るため、loose ref と packed ref の両方で
  // 分岐元の完全名を UTF-8 バイト列で確かめる。
  @Test(
    "既定の設定でかな名の branch から作った branch では、pack-refs の前後とも NFC の分岐元を使う",
    .timeLimit(.minutes(1)))
  func resolvesPrecomposedStartPoint() async throws {
    let composed = "\u{304C}"
    try await withGitRepository { repository in
      let precompose = try await repository.gitExitCode([
        "config", "--get", "core.precomposeunicode",
      ])
      try #require(precompose.exitCode == 0)
      try #require(precompose.stdout == "true\n")
      try await repository.git(["branch", composed])
      try await repository.git(["switch", "-q", "-c", "x", composed])

      let subjects = try await repository.gitExitCode([
        "reflog", "show", "--no-show-signature", "--format=%gs", "refs/heads/x", "--",
      ])
      try #require(subjects.exitCode == 0)
      try #require(
        utf8Lines(subjects.stdout).last == Array(("branch: Created from " + composed).utf8))
      let refs = try await repository.refNameLines()
      try #require(refs.contains(Array(("refs/heads/" + composed).utf8)))
      let resolved = try await repository.gitExitCode([
        "rev-parse", "--verify", "--quiet", "--symbolic-full-name", composed,
      ])
      try #require(resolved.exitCode == 0)
      try #require(Array(resolved.stdout.utf8) == Array(("refs/heads/" + composed + "\n").utf8))

      let builder = try DiffSnapshotBuilder(
        worktreeRoot: repository.mainWorktree, processRunner: FoundationProcessRunner())
      let base = await builder.resolveBaseBranch(userSelection: nil)
      #expect(base == .resolved(branch: .local(composed), source: .forkPoint))
      #expect(
        base.branch.map { Array($0.fullName.utf8) } == Array(("refs/heads/" + composed).utf8))

      try await repository.git(["pack-refs", "--all"])
      let packedRefs = try Data(
        contentsOf: repository.mainWorktree.appending(path: ".git/packed-refs"))
      let packedLines = packedRefs.split(separator: UInt8(ascii: "\n"))
      let localRef = Array((" refs/heads/" + composed).utf8)
      try #require(
        packedLines.contains { $0.suffix(localRef.count).elementsEqual(localRef) })
      try #require(
        !FileManager.default.fileExists(
          atPath: repository.mainWorktree.appending(path: ".git/refs/heads/" + composed).path))

      let packedBase = await builder.resolveBaseBranch(userSelection: nil)
      #expect(packedBase == .resolved(branch: .local(composed), source: .forkPoint))
      #expect(
        packedBase.branch.map { Array($0.fullName.utf8) }
          == Array(("refs/heads/" + composed).utf8))
    }
  }

  @Test("clone 直後のかな名の remote branch から作った branch では NFC の分岐元を使う", .timeLimit(.minutes(1)))
  func resolvesPrecomposedRemoteStartPointAfterClone() async throws {
    let composed = "\u{304C}"
    try await withGitRepository { repository in
      try await repository.git(["branch", composed])
      let clone = repository.root.appending(path: "clone")
      try await repository.git(["clone", "-q", repository.mainWorktree.path, clone.path])
      try await repository.git(["switch", "-q", "-c", "x", "origin/" + composed], in: "clone")

      let packedRefs = try Data(contentsOf: clone.appending(path: ".git/packed-refs"))
      let packedLines = packedRefs.split(separator: UInt8(ascii: "\n"))
      let remoteRef = Array((" refs/remotes/origin/" + composed).utf8)
      try #require(
        packedLines.contains { $0.suffix(remoteRef.count).elementsEqual(remoteRef) })

      let builder = try DiffSnapshotBuilder(
        worktreeRoot: clone, processRunner: FoundationProcessRunner())
      let base = await builder.resolveBaseBranch(userSelection: nil)
      #expect(base == .resolved(branch: .remote("origin/" + composed), source: .forkPoint))
      #expect(
        base.branch.map { Array($0.fullName.utf8) }
          == Array(("refs/remotes/origin/" + composed).utf8))
    }
  }

  // 製品の子 git は `HOME` を引き継ぐので、`~/.gitconfig` の `core.warnAmbiguousRefs=false` が効く。
  // そのとき曖昧な名前は警告されずに、tag が無ければ `refs/heads/` へ解決され、local branch を
  // 分岐元に採ってしまう (git 2.54.0 で計測)。偽の `HOME` を使うのは、その config を製品と同じ経路で読ませるため。
  // 対照は `-c` で与え、開発者の `~/.gitconfig` に頼らずに git の振る舞いを確かめる。
  @Test(
    "user config の core.warnAmbiguousRefs=false でも、local と remote に在る同名の分岐元を解決しない",
    .timeLimit(.minutes(1)))
  func ignoresAmbiguousStartPointUnderUserConfig() async throws {
    try await withGitRepository { repository in
      try await repository.git(["update-ref", "refs/remotes/origin/main", "HEAD"])
      try await repository.git(["branch", "origin/main", "main"])
      let refs = try await repository.refNameLines()
      try #require(refs.contains(Array("refs/heads/origin/main".utf8)))
      try #require(refs.contains(Array("refs/remotes/origin/main".utf8)))
      let control = try await repository.gitExitCode([
        "-c", "core.warnAmbiguousRefs=false",
        "rev-parse", "--verify", "--quiet", "--symbolic-full-name", "origin/main",
      ])
      try #require(control.exitCode == 0)
      try #require(control.stdout == "refs/heads/origin/main\n")

      let originMain = try #require(GitRevision("origin/main"))
      let runner = try repository.runner(
        globalConfig: "[core]\n\twarnAmbiguousRefs = false\n")
      // `HOME` の渡し方が変わって偽の `.gitconfig` が読まれなくなると、本体の `-c` を外しても
      // このテストは通ってしまう。同じ runner の経路で `false` が効いていることを先に確かめる。
      let configured = try await runner.run(
        GitReadCommand(arguments: ["config", "--get", "core.warnAmbiguousRefs"]))
      try #require(configured.stdout == "false\n")
      let result = try await runner.run(.symbolicFullName(originMain))
      #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
  }

  @Test(
    "今の branch と同名の remote-tracking ref は分岐元にしない", .timeLimit(.minutes(1)),
    arguments: [
      (
        "origin", "remote-only", ["switch", "-q", "remote-only"],
        "refs/remotes/origin/remote-only"
      ),
      ("origin", "topic", ["switch", "-q", "-c", "topic", "origin/topic"], "origin/topic"),
      ("origin", "t3", ["checkout", "-q", "--track", "origin/t3"], "origin/t3"),
      (
        "upstream", "feature", ["switch", "-q", "-c", "feature", "upstream/feature"],
        "upstream/feature"
      ),
      ("up/x", "b/feat", ["switch", "-q", "b/feat"], "refs/remotes/up/x/b/feat"),
    ])
  func ignoresSameNameRemoteTrackingStartPoint(
    remote: String, branch: String, command: [String], startPoint: String
  ) async throws {
    try await withGitRepository { repository in
      try await repository.git([
        "remote", "add", remote, repository.root.appending(path: "remote.git").path,
      ])
      try await repository.git(["update-ref", "refs/remotes/" + remote + "/" + branch, "HEAD"])
      try await repository.git(command)
      try await repository.requireOldestReflogSubject(
        "branch: Created from " + startPoint, of: "refs/heads/" + branch)

      let builder = try DiffSnapshotBuilder(
        worktreeRoot: repository.mainWorktree, processRunner: FoundationProcessRunner())
      #expect(await builder.resolveBaseBranch(userSelection: nil) == .undetermined)
    }
  }

  @Test(
    "linked worktree でも今の branch と同名の remote-tracking ref は分岐元にしない",
    .timeLimit(.minutes(1)))
  func ignoresSameNameRemoteTrackingStartPointInLinkedWorktree() async throws {
    try await withGitRepository { repository in
      try await repository.git([
        "remote", "add", "origin", repository.root.appending(path: "remote.git").path,
      ])
      try await repository.git(["update-ref", "refs/remotes/origin/t4", "HEAD"])
      let worktree = repository.root.appending(path: "wt")
      try await repository.git(["worktree", "add", "-q", worktree.path, "t4"])
      try await repository.requireOldestReflogSubject(
        "branch: Created from refs/remotes/origin/t4", of: "refs/heads/t4")

      let builder = try DiffSnapshotBuilder(
        worktreeRoot: worktree, processRunner: FoundationProcessRunner())
      #expect(await builder.resolveBaseBranch(userSelection: nil) == .undetermined)
    }
  }

  @Test(
    "今の branch と同名の remote-tracking ref を採らず origin/HEAD へ進む",
    .timeLimit(.minutes(1)))
  func fallsBackToOriginHeadForSameNameRemoteTrackingStartPoint() async throws {
    try await withGitRepository { repository in
      try await repository.git([
        "remote", "add", "origin", repository.root.appending(path: "remote.git").path,
      ])
      try await repository.git(["update-ref", "refs/remotes/origin/remote-only", "HEAD"])
      try await repository.git(["update-ref", "refs/remotes/origin/main", "HEAD"])
      try await repository.git([
        "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main",
      ])
      try await repository.git(["switch", "-q", "remote-only"])
      try await repository.requireOldestReflogSubject(
        "branch: Created from refs/remotes/origin/remote-only", of: "refs/heads/remote-only")

      let builder = try DiffSnapshotBuilder(
        worktreeRoot: repository.mainWorktree, processRunner: FoundationProcessRunner())
      #expect(
        await builder.resolveBaseBranch(userSelection: nil)
          == .resolved(branch: .remote("origin/main"), source: .originHead))
    }
  }

  @Test("末尾だけが今の branch と一致する remote-tracking ref は分岐元にする", .timeLimit(.minutes(1)))
  func resolvesRemoteTrackingStartPointWithMatchingSuffix() async throws {
    try await withGitRepository { repository in
      try await repository.git([
        "remote", "add", "origin", repository.root.appending(path: "remote.git").path,
      ])
      try await repository.git(["update-ref", "refs/remotes/origin/team/feature", "HEAD"])
      try await repository.git(["switch", "-q", "-c", "feature", "origin/team/feature"])
      try await repository.requireOldestReflogSubject(
        "branch: Created from origin/team/feature", of: "refs/heads/feature")

      let builder = try DiffSnapshotBuilder(
        worktreeRoot: repository.mainWorktree, processRunner: FoundationProcessRunner())
      #expect(
        await builder.resolveBaseBranch(userSelection: nil)
          == .resolved(branch: .remote("origin/team/feature"), source: .forkPoint))
    }
  }

  @Test("remote 名で始まる local branch は分岐元にする", .timeLimit(.minutes(1)))
  func resolvesLocalStartPointWithRemoteName() async throws {
    try await withGitRepository { repository in
      try await repository.git([
        "remote", "add", "origin", repository.root.appending(path: "remote.git").path,
      ])
      try await repository.git(["branch", "origin/feature", "main"])
      try await repository.git(["switch", "-q", "-c", "feature", "refs/heads/origin/feature"])
      try await repository.requireOldestReflogSubject(
        "branch: Created from refs/heads/origin/feature", of: "refs/heads/feature")

      let builder = try DiffSnapshotBuilder(
        worktreeRoot: repository.mainWorktree, processRunner: FoundationProcessRunner())
      #expect(
        await builder.resolveBaseBranch(userSelection: nil)
          == .resolved(branch: .local("origin/feature"), source: .forkPoint))
    }
  }

  @Test("git remote に無い名前の下の remote-tracking ref は分岐元にする", .timeLimit(.minutes(1)))
  func resolvesRemoteTrackingStartPointWithoutConfiguredRemote() async throws {
    try await withGitRepository { repository in
      try await repository.git(["update-ref", "refs/remotes/foo/feature", "HEAD"])
      try await repository.git(["switch", "-q", "-c", "feature", "refs/remotes/foo/feature"])
      try await repository.requireOldestReflogSubject(
        "branch: Created from refs/remotes/foo/feature", of: "refs/heads/feature")

      let builder = try DiffSnapshotBuilder(
        worktreeRoot: repository.mainWorktree, processRunner: FoundationProcessRunner())
      #expect(
        await builder.resolveBaseBranch(userSelection: nil)
          == .resolved(branch: .remote("foo/feature"), source: .forkPoint))
    }
  }

  @Test("`git worktree add -b` で作った worktree の分岐元を使う", .timeLimit(.minutes(1)))
  func resolvesForkPointInLinkedWorktree() async throws {
    try await withGitRepository { repository in
      try await repository.git([
        "remote", "add", "origin", repository.root.appending(path: "remote.git").path,
      ])
      try await repository.git(["update-ref", "refs/remotes/origin/main", "HEAD"])
      let worktree = repository.root.appending(path: "wt")
      try await repository.git(["worktree", "add", "-q", "-b", "wt", worktree.path, "origin/main"])
      try await repository.requireOldestReflogSubject(
        "branch: Created from origin/main", of: "refs/heads/wt")

      let builder = try DiffSnapshotBuilder(
        worktreeRoot: worktree, processRunner: FoundationProcessRunner())
      #expect(
        await builder.resolveBaseBranch(userSelection: nil)
          == .resolved(branch: .remote("origin/main"), source: .forkPoint))
    }
  }
}

extension GitTestRepository {
  func requireUpstream(_ fullName: String) async throws {
    let result = try await gitExitCode([
      "rev-parse", "--verify", "--quiet", "--symbolic-full-name", "@{upstream}",
    ])
    try #require(result.exitCode == 0)
    try #require(result.stdout == fullName + "\n")
  }

  func requireOldestReflogSubject(_ subject: String, of fullName: String) async throws {
    let result = try await gitExitCode([
      "reflog", "show", "--no-show-signature", "--format=%gs", fullName, "--",
    ])
    try #require(result.exitCode == 0)
    try #require(result.stdout.split(separator: "\n").last.map(String.init) == subject)
  }

  /// `origin/HEAD` は作らないので、分岐元を使わなければ `.undetermined` に着く。
  func switchToForkedBranch(from startPoint: String, resolvingTo fullName: String) async throws {
    try await git(["update-ref", "refs/remotes/origin/main", "HEAD"])
    try await git(["switch", "-q", "-c", "x", startPoint])
    try await requireOldestReflogSubject("branch: Created from " + startPoint, of: "refs/heads/x")
    let resolved = try await gitExitCode([
      "rev-parse", "--verify", "--quiet", "--symbolic-full-name", startPoint,
    ])
    try #require(resolved.exitCode == 0)
    try #require(resolved.stdout == fullName + "\n")
    let originHead = try await gitExitCode([
      "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD",
    ])
    try #require(originHead.exitCode == 1)
  }

  func refNameLines() async throws -> [[UInt8]] {
    let result = try await gitExitCode([
      "for-each-ref", "--format=%(refname)", "refs/heads/", "refs/remotes/",
    ])
    try #require(result.exitCode == 0)
    return utf8Lines(result.stdout)
  }
}

private func utf8Lines(_ output: String) -> [[UInt8]] {
  output.utf8.split(separator: UInt8(ascii: "\n")).map(Array.init)
}

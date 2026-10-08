import Foundation
import TerminalCore

public enum GitProjectResolutionError: Error, Sendable, Equatable {
  /// 選んだパスをディレクトリとして開けない (消えた・ファイルになった・探索権限が無い)。git を
  /// 撃つ前に分ける。`git -C` の chdir 失敗も Git repository でない場合も exit 128 で、stderr の
  /// 文言で見分けると版と locale に依存する。
  case directoryUnreachable(path: String)
  /// git が実行を終えたうえで、そのディレクトリを repository として解決しなかった。Git repository
  /// でない場合のほか、`safe.directory` の拒否等もここへ来る。原因は `GitRunnerError` の stderr に
  /// 丸めずに残す。
  case notARepository(path: String, GitRunnerError)
  /// git を起動できなかった、または終了を確かめられなかった (timeout 等)。repository でないことの
  /// 証拠にはならないので `notARepository` と分ける。
  case git(GitRunnerError)
  case unexpectedCommonDirectoryOutput(output: String)
  case worktreeList(GitRunnerError)
  case malformedWorktreeList([GitWorktreeParseFailure])
  case emptyWorktreeList
}

public enum ProjectUnavailability: Sendable, Equatable {
  case unresolvable(GitProjectResolutionError)
  /// 登録したディレクトリが、今は別の repository を指している。検出を続けると、別 repository の
  /// worktree をこの Project の名前で並べ、この Project の保存ファイルへ書き込むことになる
  /// (`GitWorktreeDetector.describe` の「common dir がこの Project のものでない」と同じ事故)。
  case replaced(by: WorktreeIdentity)
}

public enum ProjectAvailability: Sendable, Equatable {
  case available
  case unavailable(ProjectUnavailability)
}

/// 選ばれたディレクトリから Project を解決する (設計書 §16.1「既存 Local Repository」)。
///
/// 撃つ git は `GitWorktreeDetector` と同じ2つに限る: Project の同一性になる
/// `rev-parse --path-format=absolute --git-common-dir` と、Project Root を決める
/// `worktree list --porcelain -z`。どちらも main worktree・linked worktree・サブディレクトリ・
/// `.git` の中のどこから撃っても同じ値を返す (git 2.50.1 実測)。
///
/// - Important: Project Root は `worktree list` の**先頭**の entry とする。git の
///   `git-worktree(1)` は「main worktree が最初に、続いて linked worktree が並ぶ」と定めている。
///   bare repository では先頭が `bare` の付いた bare ディレクトリ自身で (git 2.50.1 実測)、
///   それを `directory` にする — `GitWorktreeDetector` はそこから撃っても linked worktree を検出し、
///   Project Root を持たない Project になる (設計書 §2.3)。
/// - Important: 同一性も `directory` も git の出力をそのまま使い、選ばれた URL から組み立てない。
///   `standardizedFileURL` は `/private` を落とし、`URL(fileURLWithPath:)` は NFC を NFD へ寄せる
///   (`GitWorktreeDetector.administrativeDirectory` の注釈)。どちらも同じ repository に別の ID を
///   与え、一覧の重複判定を外す。
public struct GitProjectResolver: Sendable {
  private static let commonDirectoryArguments = [
    "rev-parse", "--path-format=absolute", "--git-common-dir",
  ]

  /// `GitWorktreeDetector.isReachableWorkingTree` と同じ判定。同期 FS I/O を打ち切れない点も同じ。
  private static let isReachableDirectory: @Sendable (String) -> Bool = { path in
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { return false }
    return FileManager.default.isExecutableFile(atPath: path)
  }

  private let makeRunner: @Sendable (URL) throws(GitRunnerError) -> GitRunner
  private let isDirectoryReachable: @Sendable (String) -> Bool

  public init(
    processRunner: any ProcessRunning,
    executableCandidates: [URL] = GitRunner.defaultExecutableCandidates
  ) {
    self.init(
      makeRunner: { directory throws(GitRunnerError) in
        try GitRunner(
          repositoryDirectory: directory,
          processRunner: processRunner,
          executableCandidates: executableCandidates
        )
      },
      isDirectoryReachable: Self.isReachableDirectory
    )
  }

  init(
    makeRunner: @escaping @Sendable (URL) throws(GitRunnerError) -> GitRunner,
    isDirectoryReachable: @escaping @Sendable (String) -> Bool
  ) {
    self.makeRunner = makeRunner
    self.isDirectoryReachable = isDirectoryReachable
  }

  public func resolve(
    directory: URL
  ) async throws(GitProjectResolutionError) -> RegisteredProject {
    guard isDirectoryReachable(directory.path) else {
      throw .directoryUnreachable(path: directory.path)
    }
    let runner: GitRunner
    do {
      runner = try makeRunner(directory)
    } catch {
      throw .git(error)
    }

    let commonDirectory = try await commonDirectory(of: directory, runner: runner)

    let listOutput: String
    do {
      listOutput = try await runner.run(.worktreeList()).stdout
    } catch {
      throw .worktreeList(error)
    }
    let parsed = GitWorktreeList.parse(output: listOutput)
    guard parsed.failures.isEmpty else { throw .malformedWorktreeList(parsed.failures) }
    guard let main = parsed.entries.first else { throw .emptyWorktreeList }

    return RegisteredProject(commonDirectory: commonDirectory, directory: main.path)
  }

  /// 登録済みの `directory` を解決し直し、同じ repository のままかを確かめる。
  public func availability(of project: RegisteredProject) async -> ProjectAvailability {
    let resolved: RegisteredProject
    do {
      resolved = try await resolve(directory: URL(fileURLWithPath: project.directory))
    } catch {
      return .unavailable(.unresolvable(error))
    }
    guard resolved.commonDirectory == project.commonDirectory else {
      return .unavailable(.replaced(by: resolved.commonDirectory))
    }
    return .available
  }

  private func commonDirectory(
    of directory: URL,
    runner: GitRunner
  ) async throws(GitProjectResolutionError) -> WorktreeIdentity {
    let stdout: String
    do {
      stdout = try await runner.run(GitReadCommand(arguments: Self.commonDirectoryArguments))
        .stdout
    } catch {
      if case .commandFailed = error {
        throw .notARepository(path: directory.path, error)
      }
      throw .git(error)
    }
    let lines = stdout.split(separator: "\n", omittingEmptySubsequences: false)
    // 末尾の改行で空の2要素目ができる。パス自体が改行を含む場合は3要素以上になり、ここで弾く。
    guard lines.count == 2, lines[1].isEmpty,
      let identity = WorktreeIdentity(rawValue: String(lines[0]))
    else {
      throw .unexpectedCommonDirectoryOutput(output: stdout)
    }
    return identity
  }
}

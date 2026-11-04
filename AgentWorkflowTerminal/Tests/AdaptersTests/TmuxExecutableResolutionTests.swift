import Adapters
import Foundation
import Testing

@Suite("tmux 実行ファイルの解決（設計書 §4.3）")
struct TmuxExecutableResolutionTests {
  private let candidates = [
    URL(fileURLWithPath: "/test/first/tmux"),
    URL(fileURLWithPath: "/test/second/tmux"),
    URL(fileURLWithPath: "/test/third/tmux"),
  ]

  @Test("上書き無しなら最初の実行可能な候補を選ぶ", arguments: [false, true])
  func selectsFirstExecutableCandidate(firstIsExecutable: Bool) {
    var executablePaths: Set<String> = [candidates[1].path]
    if firstIsExecutable {
      executablePaths.insert(candidates[0].path)
    }

    let result = TmuxExecutableResolution.resolve(
      overridePath: nil,
      candidates: candidates,
      fileKind: { executablePaths.contains($0) ? .executableFile : .unusable }
    )

    let expected = candidates[firstIsExecutable ? 0 : 1]
    #expect(result == .found(expected, source: .defaultCandidate))
  }

  @Test("候補がどれも実行できなければ探索順をそのまま返す")
  func preservesSearchedCandidates() {
    let executablePaths: Set<String> = []
    let result = TmuxExecutableResolution.resolve(
      overridePath: nil,
      candidates: candidates,
      fileKind: { executablePaths.contains($0) ? .executableFile : .unusable }
    )

    #expect(result == .notFound(searched: candidates))
  }

  @Test("空文字と空白だけの上書きは未設定として扱う", arguments: ["", "   ", " \t\n "])
  func treatsBlankOverrideAsUnset(overridePath: String) {
    let executablePaths: Set<String> = [candidates[1].path]
    let result = TmuxExecutableResolution.resolve(
      overridePath: overridePath,
      candidates: candidates,
      fileKind: { executablePaths.contains($0) ? .executableFile : .unusable }
    )

    #expect(result == .found(candidates[1], source: .defaultCandidate))
  }

  @Test(
    "実行可能な上書きを候補より優先し、前後の空白を取り除く",
    arguments: ["/opt/local/bin/tmux", " /opt/local/bin/tmux ", "\t/opt/local/bin/tmux\n"]
  )
  func prefersTrimmedOverride(overridePath: String) {
    let overrideURL = URL(fileURLWithPath: "/opt/local/bin/tmux")
    let executablePaths = Set(candidates.map(\.path) + [overrideURL.path])
    let result = TmuxExecutableResolution.resolve(
      overridePath: overridePath,
      candidates: candidates,
      fileKind: { executablePaths.contains($0) ? .executableFile : .unusable }
    )

    #expect(result == .found(overrideURL, source: .override))
  }

  @Test(
    "実行できない上書きは候補へ落ちず、上書きだけを調べる",
    arguments: ["/opt/local/bin/tmux", " /opt/local/bin/tmux "]
  )
  func rejectsUnusableOverrideWithoutFallback(overridePath: String) {
    let executablePaths = Set(candidates.map(\.path))
    var checkedPaths: [String] = []
    let result = TmuxExecutableResolution.resolve(
      overridePath: overridePath,
      candidates: candidates,
      fileKind: { path in
        checkedPaths.append(path)
        return executablePaths.contains(path) ? .executableFile : .unusable
      }
    )

    #expect(result == .overrideNotUsable(path: "/opt/local/bin/tmux", reason: .notExecutable))
    #expect(checkedPaths == ["/opt/local/bin/tmux"])
  }

  @Test(
    "相対パスとチルダは実行可否を調べずに拒否する",
    arguments: ["tmux", "bin/tmux", " bin/tmux ", "~/bin/tmux"]
  )
  func rejectsNonAbsoluteOverrideWithoutCheckingFiles(overridePath: String) {
    let executablePaths = Set(candidates.map(\.path) + [overridePath])
    var checkedPaths: [String] = []
    let result = TmuxExecutableResolution.resolve(
      overridePath: overridePath,
      candidates: candidates,
      fileKind: { path in
        checkedPaths.append(path)
        return executablePaths.contains(path) ? .executableFile : .unusable
      }
    )

    #expect(
      result
        == .overrideNotUsable(
          path: overridePath.trimmingCharacters(in: .whitespacesAndNewlines), reason: .notAbsolute)
    )
    #expect(checkedPaths.isEmpty)
  }

  @Test("候補の省略時は TmuxRunner の既定候補を探索順のまま使う")
  func usesRunnerDefaultCandidates() {
    let executablePaths: Set<String> = []
    var checkedPaths: [String] = []
    let result = TmuxExecutableResolution.resolve(
      overridePath: nil,
      fileKind: { path in
        checkedPaths.append(path)
        return executablePaths.contains(path) ? .executableFile : .unusable
      }
    )

    #expect(result == .notFound(searched: TmuxRunner.defaultExecutableCandidates))
    #expect(checkedPaths == TmuxRunner.defaultExecutableCandidates.map(\.path))
  }

  @Test("ディレクトリの上書きは候補へ落ちず、上書きだけを調べる")
  func rejectsDirectoryOverrideWithoutFallback() {
    var checkedPaths: [String] = []
    let result = TmuxExecutableResolution.resolve(
      overridePath: "/opt/local/bin/",
      candidates: candidates,
      fileKind: { path in
        checkedPaths.append(path)
        return path == "/opt/local/bin/" ? .directory : .executableFile
      }
    )

    #expect(result == .overrideNotUsable(path: "/opt/local/bin/", reason: .isDirectory))
    #expect(checkedPaths == ["/opt/local/bin/"])
  }

  @Test("既定候補の先頭がディレクトリなら次の実行可能な候補を選ぶ")
  func skipsDirectoryCandidate() {
    var checkedPaths: [String] = []
    let result = TmuxExecutableResolution.resolve(
      overridePath: nil,
      candidates: candidates,
      fileKind: { path in
        checkedPaths.append(path)
        return path == candidates[0].path ? .directory : .executableFile
      }
    )

    #expect(result == .found(candidates[1], source: .defaultCandidate))
    #expect(checkedPaths == [candidates[0].path, candidates[1].path])
  }

  @Test("判定には前後の空白だけを取り除き、末尾スラッシュを残して渡す")
  func preservesTrailingSlashWhenCheckingOverride() {
    var checkedPaths: [String] = []
    let result = TmuxExecutableResolution.resolve(
      overridePath: " /opt/local/bin/ ",
      candidates: candidates,
      fileKind: { path in
        checkedPaths.append(path)
        return .directory
      }
    )

    #expect(checkedPaths == ["/opt/local/bin/"])
    #expect(result == .overrideNotUsable(path: "/opt/local/bin/", reason: .isDirectory))
  }

  @Test("上書きの返却 URL はディレクトリとして扱わない", arguments: ["/usr", "/opt/local/bin/"])
  func overrideURLHasNoDirectoryPath(overridePath: String) {
    let result = TmuxExecutableResolution.resolve(
      overridePath: overridePath,
      candidates: candidates,
      fileKind: { _ in .executableFile }
    )

    guard case .found(let url, let source) = result else {
      Issue.record("実行可能な上書きが選ばれなかった")
      return
    }
    #expect(source == .override)
    #expect(!url.hasDirectoryPath)
  }

  @Test("既定候補の返却 URL はディレクトリとして扱わない")
  func candidateURLHasNoDirectoryPath() {
    let result = TmuxExecutableResolution.resolve(
      overridePath: nil,
      candidates: [URL(fileURLWithPath: "/usr", isDirectory: true)],
      fileKind: { _ in .executableFile }
    )

    guard case .found(let url, let source) = result else {
      Issue.record("実行可能な既定候補が選ばれなかった")
      return
    }
    #expect(source == .defaultCandidate)
    #expect(!url.hasDirectoryPath)
  }
}

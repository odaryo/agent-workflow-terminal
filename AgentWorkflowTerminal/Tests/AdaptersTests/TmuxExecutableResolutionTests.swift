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
      isExecutableFile: { executablePaths.contains($0) }
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
      isExecutableFile: { executablePaths.contains($0) }
    )

    #expect(result == .notFound(searched: candidates))
  }

  @Test("空文字と空白だけの上書きは未設定として扱う", arguments: ["", "   ", " \t\n "])
  func treatsBlankOverrideAsUnset(overridePath: String) {
    let executablePaths: Set<String> = [candidates[1].path]
    let result = TmuxExecutableResolution.resolve(
      overridePath: overridePath,
      candidates: candidates,
      isExecutableFile: { executablePaths.contains($0) }
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
      isExecutableFile: { executablePaths.contains($0) }
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
      isExecutableFile: { path in
        checkedPaths.append(path)
        return executablePaths.contains(path)
      }
    )

    #expect(result == .overrideNotUsable(path: "/opt/local/bin/tmux", reason: .notExecutable))
    #expect(checkedPaths == ["/opt/local/bin/tmux"])
  }

  @Test(
    "相対パスとチルダは実行可否を調べずに拒否する",
    arguments: ["tmux", "bin/tmux", "~/bin/tmux"]
  )
  func rejectsNonAbsoluteOverrideWithoutCheckingFiles(overridePath: String) {
    let executablePaths = Set(candidates.map(\.path) + [overridePath])
    var checkedPaths: [String] = []
    let result = TmuxExecutableResolution.resolve(
      overridePath: overridePath,
      candidates: candidates,
      isExecutableFile: { path in
        checkedPaths.append(path)
        return executablePaths.contains(path)
      }
    )

    #expect(result == .overrideNotUsable(path: overridePath, reason: .notAbsolute))
    #expect(checkedPaths.isEmpty)
  }

  @Test("候補の省略時は TmuxRunner の既定候補を探索順のまま使う")
  func usesRunnerDefaultCandidates() {
    let executablePaths: Set<String> = []
    var checkedPaths: [String] = []
    let result = TmuxExecutableResolution.resolve(
      overridePath: nil,
      isExecutableFile: { path in
        checkedPaths.append(path)
        return executablePaths.contains(path)
      }
    )

    #expect(result == .notFound(searched: TmuxRunner.defaultExecutableCandidates))
    #expect(checkedPaths == TmuxRunner.defaultExecutableCandidates.map(\.path))
  }
}

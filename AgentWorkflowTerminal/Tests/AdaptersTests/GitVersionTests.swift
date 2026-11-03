import Foundation
import Testing

@testable import Adapters

@Suite("§17.3 git 版数の解釈と支援状況")
struct GitVersionTests {
  @Test(
    "版数出力を解釈する",
    arguments: [
      (
        "git version 2.50.1 (Apple Git-155)\n",
        GitVersionParseResult.parsed(.init(major: 2, minor: 50, patch: 1))
      ),
      ("git version 2.39.0", .parsed(.init(major: 2, minor: 39, patch: 0))),
      ("git version 2.39", .parsed(.init(major: 2, minor: 39, patch: 0))),
      ("git version 2.45.2.windows.1", .parsed(.init(major: 2, minor: 45, patch: 2))),
      ("git version 2.47.0.dirty", .parsed(.init(major: 2, minor: 47, patch: 0))),
      ("git version 2.56.GIT", .parsed(.init(major: 2, minor: 56, patch: 0))),
      ("git version 2.38.GIT", .parsed(.init(major: 2, minor: 38, patch: 0))),
      ("git version 2.39.x", .unparsable("git version 2.39.x")),
      ("git version 2.39.", .unparsable("git version 2.39.")),
      ("git version 2.39.０", .unparsable("git version 2.39.０")),
      ("git version 2.39.rc1", .unparsable("git version 2.39.rc1")),
      ("git version 2.39.0rc1", .parsed(.init(major: 2, minor: 39, patch: 0))),
      ("git version 2.56.0.12.gabcdef.dirty", .parsed(.init(major: 2, minor: 56, patch: 0))),
      ("git version 2.39.0-rc1", .unparsable("git version 2.39.0-rc1")),
      ("git version 2.39.0.rc1", .unparsable("git version 2.39.0.rc1")),
      ("", .unparsable("")),
      ("git version", .unparsable("git version")),
      ("git version x.y", .unparsable("git version x.y")),
      ("tmux 3.4", .unparsable("tmux 3.4")),
      ("git version 2", .unparsable("git version 2")),
      ("git version ２.39.0", .unparsable("git version ２.39.0")),
      ("git version 2.３９.0", .unparsable("git version 2.３９.0")),
    ]
  )
  func parsesVersionOutput(versionOutput: String, expected: GitVersionParseResult) {
    #expect(GitVersion.parse(versionOutput: versionOutput) == expected)
  }

  @Test("前後の空白と末尾改行を無視する")
  func ignoresSurroundingWhitespace() {
    #expect(
      GitVersion.parse(versionOutput: " \t git version 2.39.0\n ")
        == .parsed(.init(major: 2, minor: 39, patch: 0)))
  }

  @Test(
    "下限 2.39.0 の境界から支援状況を判定する",
    arguments: [
      (
        GitVersion(major: 2, minor: 38, patch: 9),
        GitVersionSupport.unsupported(
          .init(major: 2, minor: 38, patch: 9), minimum: .init(major: 2, minor: 39, patch: 0))
      ),
      (
        GitVersion(major: 2, minor: 39, patch: 0),
        .supported(.init(major: 2, minor: 39, patch: 0))
      ),
      (
        GitVersion(major: 3, minor: 0, patch: 0),
        .supported(.init(major: 3, minor: 0, patch: 0))
      ),
      (
        GitVersion(major: 1, minor: 99, patch: 99),
        .unsupported(
          .init(major: 1, minor: 99, patch: 99), minimum: .init(major: 2, minor: 39, patch: 0))
      ),
      (
        GitVersion(major: 2, minor: 50, patch: 1),
        .supported(.init(major: 2, minor: 50, patch: 1))
      ),
    ]
  )
  func determinesSupport(version: GitVersion, expected: GitVersionSupport) {
    #expect(GitVersion.support(for: .parsed(version)) == expected)
  }

  @Test(
    "解釈できない版数を原文付きの unknown のまま返す",
    arguments: ["git version x.y\n", "git version 2.39.0-rc1\n", "git version 2.39.0.rc1\n"]
  )
  func preservesUnknownVersionOutput(rawOutput: String) {
    #expect(
      GitVersion.support(for: .unparsable(rawOutput)) == .unknown(rawOutput: rawOutput))
  }

  @Test("repository の引数を付けず --version だけを実行する")
  func requestsVersionWithoutRepository() async throws {
    let spy = GitVersionProcessSpy(
      result: .success(.init(exitCode: 0, stdout: "git version 2.39.0", stderr: "")))

    _ = try await GitVersion.detect(
      executableCandidates: [URL(fileURLWithPath: "/git")], processRunner: spy,
      parentEnvironment: [:], isExecutableFile: { _ in true })

    #expect(await spy.calls.count == 1)
    let call = try #require(await spy.calls.first)
    #expect(call.arguments == ["--version"])
    #expect(call.environment["LC_ALL"] == "C")
    #expect(call.timeout == .seconds(5))
  }

  @Test(
    "stdout から版数の支援状態を返す",
    arguments: [
      (
        "git version 2.50.1 (Apple Git-155)\n",
        GitVersionSupport.supported(.init(major: 2, minor: 50, patch: 1))
      ),
      (
        "git version 2.38.9\n",
        .unsupported(
          .init(major: 2, minor: 38, patch: 9), minimum: .init(major: 2, minor: 39, patch: 0))
      ),
      ("git version 2.56.GIT", .supported(.init(major: 2, minor: 56, patch: 0))),
      (
        "git version 2.38.GIT",
        .unsupported(
          .init(major: 2, minor: 38, patch: 0), minimum: .init(major: 2, minor: 39, patch: 0))
      ),
      ("git version 2.39.x", .unknown(rawOutput: "git version 2.39.x")),
      ("git version 2.39.", .unknown(rawOutput: "git version 2.39.")),
      ("git version 2.39.０", .unknown(rawOutput: "git version 2.39.０")),
      ("git version 2.39.rc1", .unknown(rawOutput: "git version 2.39.rc1")),
      ("git version x.y\n", .unknown(rawOutput: "git version x.y\n")),
    ]
  )
  func detectsSupport(stdout: String, expected: GitVersionSupport) async throws {
    let spy = GitVersionProcessSpy(
      result: .success(.init(exitCode: 0, stdout: stdout, stderr: "git version 1.0.0")))

    let support = try await GitVersion.detect(
      executableCandidates: [URL(fileURLWithPath: "/git")], processRunner: spy,
      parentEnvironment: [:], isExecutableFile: { _ in true })

    #expect(support == expected)
  }

  @Test("版数取得の非ゼロ終了を unknown に丸めずエラーにする")
  func rejectsFailedVersionCommand() async throws {
    let spy = GitVersionProcessSpy(
      result: .success(.init(exitCode: 1, stdout: "partial", stderr: "failed\n")))

    await #expect(
      throws: GitVersionDetectionError.commandFailed(
        exitCode: 1, stdout: "partial", stderr: "failed\n")
    ) {
      try await GitVersion.detect(
        executableCandidates: [URL(fileURLWithPath: "/git")], processRunner: spy,
        parentEnvironment: [:], isExecutableFile: { _ in true })
    }
  }

  @Test(
    "起動失敗と timeout を実行層エラーとして保持する",
    arguments: [
      ProcessRunnerError.launchFailed(
        executableURL: URL(fileURLWithPath: "/git"), message: "missing"),
      .timedOut(exitCode: nil, stdout: "partial", stderr: ""),
    ]
  )
  func preservesProcessErrors(error: ProcessRunnerError) async throws {
    let spy = GitVersionProcessSpy(result: .failure(error))

    await #expect(throws: GitVersionDetectionError.process(error)) {
      try await GitVersion.detect(
        executableCandidates: [URL(fileURLWithPath: "/git")], processRunner: spy,
        parentEnvironment: [:], isExecutableFile: { _ in true })
    }
  }
  @Test(
    "子には LC_ALL と親に存在する HOME / PATH だけを渡す",
    arguments: [
      (
        [
          "HOME": "/home", "PATH": "/bin", "DEVELOPER_DIR": "/developer",
          "GIT_CONFIG_GLOBAL": "/config", "LC_ALL": "ja_JP.UTF-8",
        ],
        ["LC_ALL": "C", "HOME": "/home", "PATH": "/bin"]
      ),
      (["DEVELOPER_DIR": "/developer", "GIT_CONFIG_GLOBAL": "/config"], ["LC_ALL": "C"]),
    ]
  )
  func restrictsEnvironment(parent: [String: String], expected: [String: String]) async throws {
    let spy = GitVersionProcessSpy(
      result: .success(.init(exitCode: 0, stdout: "git version 2.39.0", stderr: "")))

    _ = try await GitVersion.detect(
      executableCandidates: [URL(fileURLWithPath: "/git")], processRunner: spy,
      parentEnvironment: parent, isExecutableFile: { _ in true })

    let call = try #require(await spy.calls.first)
    #expect(call.environment == expected)
  }

  @Test("候補のうち最初に実行できる git と指定した timeout を使う")
  func selectsFirstExecutableAndForwardsTimeout() async throws {
    let candidates = ["/missing/git", "/second/git", "/third/git"].map { URL(fileURLWithPath: $0) }
    let spy = GitVersionProcessSpy(
      result: .success(.init(exitCode: 0, stdout: "git version 2.39.0", stderr: "")))

    _ = try await GitVersion.detect(
      executableCandidates: candidates, processRunner: spy, timeout: .milliseconds(123),
      parentEnvironment: [:], isExecutableFile: { $0.path != "/missing/git" })

    #expect(await spy.calls.count == 1)
    let call = try #require(await spy.calls.first)
    #expect(call.executableURL == candidates[1])
    #expect(call.timeout == .milliseconds(123))
  }

  @Test(
    "実行できる候補が無ければプロセスを起動せず候補付きエラーを返す",
    arguments: [
      [URL](), [URL(fileURLWithPath: "/missing/git"), URL(fileURLWithPath: "/other/git")],
    ])
  func rejectsMissingBinary(candidates: [URL]) async {
    let spy = GitVersionProcessSpy(
      result: .success(.init(exitCode: 0, stdout: "git version 2.39.0", stderr: "")))

    await #expect(throws: GitVersionDetectionError.binaryNotFound(candidates: candidates)) {
      try await GitVersion.detect(
        executableCandidates: candidates, processRunner: spy,
        parentEnvironment: [:], isExecutableFile: { _ in false })
    }
    #expect(await spy.calls.isEmpty)
  }

  @Test("Int に収まらない数値を解釈不能のまま返す", arguments: [0, 1, 2])
  func rejectsOverflow(componentIndex: Int) {
    var components = ["2", "39", "0"]
    components[componentIndex] = String(Int.max) + "0"
    let output = "git version " + components.joined(separator: ".")
    #expect(GitVersion.parse(versionOutput: output) == .unparsable(output))
  }

}

private actor GitVersionProcessSpy: ProcessRunning {
  struct Call: Sendable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let timeout: Duration
  }

  private(set) var calls: [Call] = []
  let result: Result<ProcessRunResult, ProcessRunnerError>

  init(result: Result<ProcessRunResult, ProcessRunnerError>) {
    self.result = result
  }

  func run(
    executableURL: URL, arguments: [String], environment: [String: String], timeout: Duration,
    outputLimit: Int
  ) throws(ProcessRunnerError) -> ProcessRunResult {
    calls.append(
      .init(
        executableURL: executableURL, arguments: arguments, environment: environment,
        timeout: timeout))
    return try result.get()
  }
}

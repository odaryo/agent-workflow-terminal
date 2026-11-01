import Adapters
import Foundation
import Testing

@Suite("取り残された tmux server の lsof probe")
struct TmuxOrphanedServerProbeTests {
  @Test("既定の executable・argv・3秒の timeout で lsof を起動する")
  func usesDefaultInvocation() async {
    let runner = OrphanedServerRunnerStub(result: stubSuccess())
    _ = await TmuxOrphanedServerProbe(runner: runner).probe(socketPath: measuredOrphanedSocketPath)

    #expect(await runner.environments.first?["LC_ALL"] == "C")
    #expect(
      await runner.invocations == [
        .init(
          executableURL: URL(fileURLWithPath: "/usr/sbin/lsof"),
          arguments: ["-w", "-U", "-a", "-c", "tmux", "-F", "pn"], timeout: .seconds(3))
      ])
  }

  @Test("executable と timeout は注入できる")
  func usesInjectedConfiguration() async {
    let runner = OrphanedServerRunnerStub(result: stubSuccess())
    let executable = URL(fileURLWithPath: "/test/bin/lsof")
    _ = await TmuxOrphanedServerProbe(
      runner: runner, executable: executable, timeout: .milliseconds(250)
    ).probe(socketPath: measuredOrphanedSocketPath)

    #expect(await runner.invocations.first?.executableURL == executable)
    #expect(await runner.invocations.first?.timeout == .milliseconds(250))
  }

  @Test("exit 0 で socket の完全一致があれば orphaned")
  func findsOrphanedServer() async throws {
    let runner = OrphanedServerRunnerStub(result: stubSuccess(stdout: try measuredLsofOutput()))
    #expect(
      await TmuxOrphanedServerProbe(runner: runner).probe(socketPath: measuredOrphanedSocketPath)
        == .orphaned(processIDs: [15199]))
  }

  @Test(
    "exit 0 の一致なしと、exit 1 で stdout も stderr も空なら absent",
    arguments: [
      ProcessRunResult(exitCode: 0, stdout: "", stderr: ""),
      ProcessRunResult(exitCode: 0, stdout: "p123\nn/another/socket\n", stderr: ""),
      ProcessRunResult(exitCode: 1, stdout: "", stderr: ""),
    ])
  func reportsAbsence(output: ProcessRunResult) async {
    let runner = OrphanedServerRunnerStub(result: .success(output))
    #expect(
      await TmuxOrphanedServerProbe(runner: runner).probe(socketPath: measuredOrphanedSocketPath)
        == .absent)
  }

  @Test(
    "exit 1 の非空 stdout・exit 1 の stderr・その他の終了コードは理由付きの undetermined",
    arguments: [
      ProcessRunResult(exitCode: 1, stdout: "p123\nn/socket\n", stderr: ""),
      // lsof はどのエラーでも exit 1 を返すので、stderr があれば不在とは言えない。
      ProcessRunResult(exitCode: 1, stdout: "", stderr: "diagnostic\n"),
      ProcessRunResult(exitCode: 1, stdout: "\n", stderr: ""),
      ProcessRunResult(exitCode: 2, stdout: "", stderr: "lsof failed\n"),
      ProcessRunResult(exitCode: 2, stdout: "p123\nn/socket\n", stderr: "lsof failed\n"),
      ProcessRunResult(exitCode: 15, stdout: "", stderr: ""),
    ])
  func rejectsUncertainExit(output: ProcessRunResult) async {
    await expectUndetermined(.success(output))
  }

  @Test(
    "起動失敗・timeout などの実行エラーは理由付きの undetermined",
    arguments: [
      ProcessRunnerError.launchFailed(
        executableURL: URL(fileURLWithPath: "/usr/sbin/lsof"), message: "not executable"),
      .timedOut(exitCode: nil, stdout: "", stderr: ""),
      .timedOut(exitCode: 0, stdout: "p123\nn/socket\n", stderr: ""),
      .cancelled,
      .outputLimitExceeded(limit: 10),
      .outputReadFailed(message: "read failed"),
      .invalidOutputLimit(-1),
    ])
  func rejectsRunnerFailure(error: ProcessRunnerError) async {
    await expectUndetermined(.failure(error))
  }

  @Test(
    "lsof がそのまま出さない文字を含むパスは、exit 1 で出力が空でも undetermined",
    arguments: lsofEscapedPathCases)
  func rejectsEmptyOutputForEscapedPath(path: LsofEscapedPathCase) async {
    await expectUndetermined(
      .success(.init(exitCode: 1, stdout: "", stderr: "")), socketPath: path.socketPath)
  }

  @Test(
    "lsof がそのまま出さない文字を含むパスは、exit 0 で一致する行が無くても undetermined",
    arguments: lsofEscapedPathCases)
  func rejectsUnmatchedOutputForEscapedPath(path: LsofEscapedPathCase) async {
    await expectUndetermined(
      stubSuccess(stdout: path.unmatchedLsofOutput), socketPath: path.socketPath)
  }

  @Test("lsof がそのまま出さない文字を含むパスでも、完全一致する行があれば orphaned")
  func findsServerForEscapedPathWhenLineMatches() async {
    let socketPath = "/private/tmp/tmux-501/awt-a^b"
    let runner = OrphanedServerRunnerStub(
      result: stubSuccess(
        stdout: "p20378\nf6\nn/private/tmp/tmux-501/default\np54148\nf6\nn\(socketPath)\n"))
    #expect(
      await TmuxOrphanedServerProbe(runner: runner).probe(socketPath: socketPath)
        == .orphaned(processIDs: [54148]))
  }

  @Test(
    "印字できる ASCII だけのパスは、exit 0 で一致する行が無ければ absent",
    arguments: [
      "/private/tmp/tmux-501/awtm500",
      // 空白と ` (` は lsof と tmux の stderr で同じ表記になる (Issue #500 のレビューの計測)。
      "/private/tmp/tmux-501/awt a (1)",
      // 0x20 と 0x7E は印字できる ASCII の両端。
      "/private/tmp/tmux-501/ ~",
    ])
  func reportsAbsenceForPrintableASCIIPath(socketPath: String) async {
    let runner = OrphanedServerRunnerStub(
      result: stubSuccess(
        stdout: "p20378\nf6\nn/private/tmp/tmux-501/default\np123\nf6\nn->0x57eff5ebf5b56053\n"))
    #expect(await TmuxOrphanedServerProbe(runner: runner).probe(socketPath: socketPath) == .absent)
  }

  private func expectUndetermined(
    _ result: TmuxSessionStubResult, socketPath: String = "/socket"
  ) async {
    let runner = OrphanedServerRunnerStub(result: result)
    let actual = await TmuxOrphanedServerProbe(runner: runner).probe(socketPath: socketPath)
    guard case .undetermined(let reason) = actual else {
      Issue.record("理由付きの undetermined を期待したが、\(actual) が返った")
      return
    }
    #expect(!reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }
}

actor OrphanedServerRunnerStub: ProcessRunning {
  struct Invocation: Sendable, Equatable {
    let executableURL: URL
    let arguments: [String]
    let timeout: Duration
  }

  private let result: TmuxSessionStubResult
  private(set) var invocations: [Invocation] = []
  private(set) var environments: [[String: String]] = []

  init(result: TmuxSessionStubResult) {
    self.result = result
  }

  func run(
    executableURL: URL, arguments: [String], environment: [String: String], timeout: Duration,
    outputLimit: Int
  ) async throws(ProcessRunnerError) -> ProcessRunResult {
    environments.append(environment)
    invocations.append(
      .init(executableURL: executableURL, arguments: arguments, timeout: timeout))
    return try result.get()
  }
}

/// `lsofName` は、そのパスの server を lsof (`LC_ALL=C`、revision 4.91) が `n` 行に出す表記。
/// 非 ASCII・タブ・バックスラッシュ・制御文字は Issue #500 のレビューの計測による。`nil` は表記を
/// 計測していないもの。
struct LsofEscapedPathCase: Sendable, CustomTestStringConvertible {
  let label: String
  let socketPath: String
  let lsofName: String?

  var testDescription: String { label }

  var unmatchedLsofOutput: String {
    let other = "p20378\nf6\nn/private/tmp/tmux-501/default\n"
    guard let lsofName else { return other }
    return other + "p54148\nf6\nn\(lsofName)\n"
  }
}

let lsofEscapedPathCases = [
  LsofEscapedPathCase(
    label: "非 ASCII", socketPath: "/private/tmp/tmux-501/awt-日本",
    lsofName: #"/private/tmp/tmux-501/awt-\xe6\x97\xa5\xe6\x9c\xac"#),
  LsofEscapedPathCase(
    label: "タブ", socketPath: "/private/tmp/tmux-501/awt-a\tb",
    lsofName: #"/private/tmp/tmux-501/awt-a\tb"#),
  LsofEscapedPathCase(
    label: "バックスラッシュ", socketPath: #"/private/tmp/tmux-501/awt-a\b"#,
    lsofName: #"/private/tmp/tmux-501/awt-a\\b"#),
  LsofEscapedPathCase(
    label: "制御文字", socketPath: "/private/tmp/tmux-501/awt-a\u{01}b",
    lsofName: "/private/tmp/tmux-501/awt-a^Ab"),
  LsofEscapedPathCase(
    label: "キャレット", socketPath: "/private/tmp/tmux-501/awt-a^b", lsofName: nil),
  LsofEscapedPathCase(
    label: "DEL (0x7F)", socketPath: "/private/tmp/tmux-501/awt-a\u{7F}b", lsofName: nil),
]

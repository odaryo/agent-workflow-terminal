import Foundation
import RemoteClient
import Testing

@Suite("tmux 3.8 のリモートセッション一覧")
struct RemoteTmuxSessionListTests {
  private func fixture(_ name: String) throws -> String {
    let url = try #require(
      Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures"))
    return String(decoding: try Data(contentsOf: url), as: UTF8.self)
  }

  private var measuredSessions: [RemoteTmuxSession] {
    [
      RemoteTmuxSession(id: "$5", attachedClients: 0, name: "awt-repo-0123abcd-2"),
      RemoteTmuxSession(id: "$4", attachedClients: 0, name: "a|b  c "),
      RemoteTmuxSession(id: "$3", attachedClients: 0, name: #"bs\\x"#),
      RemoteTmuxSession(id: "$0", attachedClients: 0, name: "m806"),
      RemoteTmuxSession(id: "$1", attachedClients: 0, name: "sp 'q"),
      RemoteTmuxSession(id: "$2", attachedClients: 0, name: "計測"),
    ]
  }

  @Test("実測 fixture の順序・空白・二重バックスラッシュ・日本語を保持する")
  func parsesMeasuredFixture() throws {
    let stdout = try fixture("tmux-3.8-list-sessions")
    let result = RemoteTmuxSessionList.parse(output: stdout)
    let sessions = result.sessions
    #expect(result.failures.isEmpty)
    #expect(sessions == measuredSessions)
    #expect(sessions.map(\.id) == ["$5", "$4", "$3", "$0", "$1", "$2"])
  }

  @Test("fixture の正式名から現在の ID を引いて attach する")
  func attachesUsingCurrentID() throws {
    let result = RemoteTmuxSessionList.parse(output: try fixture("tmux-3.8-list-sessions"))
    for expected in measuredSessions {
      #expect(result.session(named: expected.name) == expected)
    }
    #expect(result.session(named: "missing") == nil)
    #expect(result.session(named: "a|b  c") == nil)
    let session = try #require(result.session(named: #"bs\\x"#))
    #expect(
      RemoteTmuxCommand.attach(tmuxPath: "/tmux", sessionID: session.id)
        == "'/tmux' -u attach-session -t '$3'")
  }

  @Test("名前は正準等価でも UTF-8 のバイト列が違えば別名とする")
  func exactNameBytes() throws {
    let result = RemoteTmuxSessionList.parse(
      output: "$1 0 é\n$3 0 e\u{301}\n$5 0 a:b\n$6 0 x.0\n$7 0 $0\n")
    #expect(result.session(named: "é")?.id == "$1")
    #expect(result.session(named: "e\u{301}")?.id == "$3")
    #expect(result.session(named: "a:b")?.id == "$5")
    #expect(result.session(named: "x.0")?.id == "$6")
    #expect(result.session(named: "$0")?.id == "$7")
    let single = RemoteTmuxSessionList.parse(output: "$9 0 é\n")
    #expect(single.session(named: "e\u{301}") == nil)
    let restarted = RemoteTmuxSessionList.parse(output: "$0 0 a:b\n")
    #expect(restarted.session(named: "a:b")?.id == "$0")
  }

  @Test("異常行の行番号・原文・理由を残し、前後の正常行も保持する")
  func recordsMalformedLines() throws {
    let malformed: [(String, RemoteTmuxSessionListParseError)] = [
      ("", .missingFields), ("garbage", .missingFields),
      ("5 0 name", .invalidSessionID("5")), ("$ 0 name", .invalidSessionID("$")),
      ("$x 0 name", .invalidSessionID("$x")), ("$-1 0 name", .invalidSessionID("$-1")),
      ("$1x 0 name", .invalidSessionID("$1x")),
      ("$1 nope name", .invalidAttachedClients("nope")),
      ("$1 -1 name", .invalidAttachedClients("-1")),
      ("$1 1.5 name", .invalidAttachedClients("1.5")),
      ("$1 +1 name", .invalidAttachedClients("+1")),
      ("$1 0", .missingFields), ("$1", .missingFields),
      (
        "$1 9999999999999999999999999999999999999999 name",
        .invalidAttachedClients("9999999999999999999999999999999999999999")
      ),
    ]
    let stdout = try fixture("tmux-3.8-list-sessions")
    let output = stdout + malformed.map(\.0).joined(separator: "\n") + "\n" + stdout
    let expectedFailures = malformed.enumerated().map { index, entry in
      RemoteTmuxSessionListParseFailure(
        lineNumber: measuredSessions.count + index + 1, line: entry.0, error: entry.1)
    }
    let expected = RemoteTmuxSessionListParseResult(
      sessions: measuredSessions + measuredSessions, failures: expectedFailures)
    #expect(RemoteTmuxSessionList.parse(output: output) == expected)
    #expect(RemoteTmuxSessionList.parse(output: String(output.dropLast())) == expected)
    for (line, error) in malformed {
      #expect(throws: error) { try RemoteTmuxSessionList.parse(line: line) }
    }
  }

  @Test("10進数の attachedClients と名前の先頭・末尾空白を保持する")
  func attachedClientsAndSpaces() throws {
    let line = "$12 17  leading  trailing "
    let session = RemoteTmuxSession(id: "$12", attachedClients: 17, name: " leading  trailing ")
    #expect(try RemoteTmuxSessionList.parse(line: line) == session)
    #expect(
      RemoteTmuxSessionList.parse(output: line + "\n")
        == RemoteTmuxSessionListParseResult(sessions: [session], failures: []))
  }

  @Test("最終行に改行がなくても同じ結果になり、空出力は成功も失敗も空")
  func noFinalNewline() throws {
    let stdout = try fixture("tmux-3.8-list-sessions")
    let expected = RemoteTmuxSessionListParseResult(sessions: measuredSessions, failures: [])
    #expect(RemoteTmuxSessionList.parse(output: String(stdout.dropLast())) == expected)
    #expect(RemoteTmuxSessionList.parse(output: "") == .init(sessions: [], failures: []))
  }

  @Test("末尾の改行は1つだけ除き、それ以外の空行は失敗に残す")
  func preservesEmptyLines() {
    #expect(
      RemoteTmuxSessionList.parse(output: "\n\n")
        == .init(
          sessions: [],
          failures: [
            .init(lineNumber: 1, line: "", error: .missingFields),
            .init(lineNumber: 2, line: "", error: .missingFields),
          ]))
  }

  @Test("exit 0 は stderr があっても一覧として返す")
  func successfulOutcome() throws {
    let stdout = try fixture("tmux-3.8-list-sessions")
    #expect(
      RemoteTmuxSessionList.outcome(exitStatus: 0, stdout: stdout, stderr: "warning\n")
        == .sessions(.init(sessions: measuredSessions, failures: [])))
    #expect(
      RemoteTmuxSessionList.outcome(exitStatus: 0, stdout: "", stderr: "")
        == .sessions(.init(sessions: [], failures: [])))
  }

  @Test("exit 0 の一覧は解析の失敗も保持する")
  func successfulOutcomeWithParseFailures() {
    #expect(
      RemoteTmuxSessionList.outcome(exitStatus: 0, stdout: "broken\n", stderr: "")
        == .sessions(
          .init(
            sessions: [],
            failures: [
              .init(lineNumber: 1, line: "broken", error: .missingFields)
            ])))
  }

  @Test(
    "server 不在と socket 不在の実測 stderr は exit 1 のとき noServer",
    arguments: [
      "tmux-3.8-list-sessions-no-server.stderr", "tmux-3.8-list-sessions-no-socket.stderr",
    ]
  )
  func noServer(name: String) throws {
    let stderr = try fixture(name)
    #expect(
      RemoteTmuxSessionList.outcome(exitStatus: 1, stdout: "", stderr: stderr) == .noServer)
    #expect(
      RemoteTmuxSessionList.outcome(exitStatus: 1, stdout: "", stderr: " \t" + stderr + "\n ")
        == .noServer)
  }

  @Test(
    "不在メッセージでも exit 1 以外は失敗",
    arguments: [0, 2, -1, nil] as [Int?]
  )
  func noServerRequiresExitOne(status: Int?) throws {
    let stderr = try fixture("tmux-3.8-list-sessions-no-server.stderr")
    let expected: RemoteTmuxSessionList.Outcome =
      status == 0
      ? .sessions(.init(sessions: [], failures: []))
      : .failed(
        exitStatus: status, message: stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    #expect(
      RemoteTmuxSessionList.outcome(exitStatus: status, stdout: "", stderr: stderr) == expected)
  }

  @Test(
    "その他の失敗は exit-status と前後の空白だけを除いた stderr を保持する",
    arguments: [
      (1 as Int?, " \tpermission denied\n", "permission denied"),
      (255 as Int?, "\nconnection lost\n detail \n", "connection lost\n detail"),
      (nil, " \n tcpShutdown \t", "tcpShutdown"),
      (2 as Int?, " \t\n", ""),
      (
        1 as Int?, "prefix no server running on /tmp/socket",
        "prefix no server running on /tmp/socket"
      ),
      (
        1 as Int?, "error connecting to /tmp/socket (Permission denied)",
        "error connecting to /tmp/socket (Permission denied)"
      ),
      (1 as Int?, "error connecting to /tmp/socket", "error connecting to /tmp/socket"),
      (
        1 as Int?, "error connecting to /tmp/socket (No such file or directory) extra",
        "error connecting to /tmp/socket (No such file or directory) extra"
      ),
    ]
  )
  func failedOutcome(status: Int?, stderr: String, message: String) {
    #expect(
      RemoteTmuxSessionList.outcome(exitStatus: status, stdout: "$0 0 ignored\n", stderr: stderr)
        == .failed(exitStatus: status, message: message))
  }
}

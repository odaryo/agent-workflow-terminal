import TerminalCore
import Testing

@Suite("hostctl protocol と引数の解釈 §21.4")
struct HostControlTests {
  @Test("要求をキー順のJSONにして往復する")
  func requestRoundTrip() throws {
    let request = HostControlRequest.openWorktree(directory: "/path")
    let line = #"{"command":"worktree.open","directory":"/path","version":1}"#
    #expect(HostControlProtocol.version == 1)
    #expect(HostControlProtocol.encode(request) == line)
    #expect(try HostControlProtocol.decodeRequest(line).get() == request)
    #expect(
      try HostControlProtocol.decodeRequest(HostControlProtocol.encode(request)).get() == request)
  }

  @Test("成功応答はagentCommandのnullも省かずキー順にする")
  func openedWithNullCommand() throws {
    let response = HostControlResponse.opened(
      HostControlOpenedWorktree(
        session: "awt-x-12345678", directory: "/path", created: true, agentCommand: nil))
    let line =
      #"{"agentCommand":null,"created":true,"directory":"/path","ok":true,"#
      + #""session":"awt-x-12345678","version":1}"#
    #expect(HostControlProtocol.encode(response) == line)
    #expect(try HostControlProtocol.decodeResponse(line).get() == response)
    #expect(
      try HostControlProtocol.decodeResponse(HostControlProtocol.encode(response)).get() == response
    )
  }

  @Test("成功応答のagentCommand文字列とcreated falseを往復する")
  func openedWithCommand() throws {
    let response = HostControlResponse.opened(
      HostControlOpenedWorktree(
        session: "awt-x-12345678", directory: "/path", created: false,
        agentCommand: "agent --resume"))
    let line =
      #"{"agentCommand":"agent --resume","created":false,"#
      + #""directory":"/path","ok":true,"session":"awt-x-12345678","version":1}"#
    #expect(HostControlProtocol.encode(response) == line)
    #expect(try HostControlProtocol.decodeResponse(line).get() == response)
    #expect(
      try HostControlProtocol.decodeResponse(HostControlProtocol.encode(response)).get() == response
    )
  }

  @Test(
    "全失敗コードをキー順のJSONにして往復する",
    arguments: [
      (HostControlFailureCode.invalidRequest, "invalid_request"),
      (.notRegistered, "not_registered"),
      (.projectRoot, "project_root"),
      (.unreachable, "unreachable"),
      (.tmuxFailed, "tmux_failed"),
    ]
  )
  func failureRoundTrip(code: HostControlFailureCode, rawValue: String) throws {
    let response = HostControlResponse.failure(code: code, message: "失敗")
    let line = "{\"code\":\"\(rawValue)\",\"message\":\"失敗\",\"ok\":false,\"version\":1}"
    #expect(code.rawValue == rawValue)
    #expect(HostControlProtocol.encode(response) == line)
    #expect(try HostControlProtocol.decodeResponse(line).get() == response)
    #expect(
      try HostControlProtocol.decodeResponse(HostControlProtocol.encode(response)).get() == response
    )
  }

  @Test(
    "未知のcommandやversion、小数表記のversion、不正JSON、directory欠落を拒否する",
    arguments: [
      #"{"version":1,"command":"unknown","directory":"/path"}"#,
      #"{"version":2,"command":"worktree.open","directory":"/path"}"#,
      #"{"version":1.0,"command":"worktree.open","directory":"/path"}"#,
      "{",
      #"{"version":1,"command":"worktree.open"}"#,
    ]
  )
  func rejectsInvalidRequest(line: String) {
    guard case .failure = HostControlProtocol.decodeRequest(line) else {
      Issue.record("不正な要求を受け付けた: \(line)")
      return
    }
  }

  @Test(
    "未知のversion、不正JSON、成功応答のdirectory欠落を拒否する",
    arguments: [
      #"{"version":2,"ok":false,"code":"not_registered","message":"失敗"}"#,
      "{",
      #"{"version":1,"ok":true,"session":"s","created":true,"agentCommand":null}"#,
    ]
  )
  func rejectsInvalidResponse(line: String) {
    guard case .failure = HostControlProtocol.decodeResponse(line) else {
      Issue.record("不正な応答を受け付けた: \(line)")
      return
    }
  }

  @Test("改行のあるパスも要求と応答を1行で往復する")
  func newlineInDirectory() throws {
    let request = HostControlRequest.openWorktree(directory: "/line\nbreak")
    let response = HostControlResponse.opened(
      HostControlOpenedWorktree(
        session: "s", directory: "/line\nbreak", created: true, agentCommand: nil))
    let requestLine = HostControlProtocol.encode(request)
    let responseLine = HostControlProtocol.encode(response)
    #expect(!requestLine.contains("\n"))
    #expect(!responseLine.contains("\n"))
    #expect(requestLine.contains(#"/line\nbreak"#))
    #expect(responseLine.contains(#"/line\nbreak"#))
    #expect(try HostControlProtocol.decodeRequest(requestLine).get() == request)
    #expect(try HostControlProtocol.decodeResponse(responseLine).get() == response)
  }

  @Test("不正JSONのエラーにデコーダの内部表現を出さない", arguments: ["{", "{}"])
  func readableDecodingErrors(line: String) {
    guard case .failure(let requestError) = HostControlProtocol.decodeRequest(line),
      case .failure(let responseError) = HostControlProtocol.decodeResponse(line)
    else {
      Issue.record("不正JSONを受け付けた")
      return
    }
    #expect(requestError.message == "要求のJSON形式が不正です")
    #expect(responseError.message == "応答のJSON形式が不正です")
  }

  @Test("必須引数を解釈する")
  func parsesDirectory() throws {
    let result = HostControlCommandLine.parse(["worktree", "open", "--directory", "/two words/日本語"])
    #expect(try result.get() == .openWorktree(directory: "/two words/日本語", socket: nil))
  }

  @Test("socket指定を解釈する")
  func parsesSocket() throws {
    let result = HostControlCommandLine.parse(
      ["worktree", "open", "--directory", "/path", "--socket", "/private/tmp/host.sock"])
    #expect(
      try result.get() == .openWorktree(directory: "/path", socket: "/private/tmp/host.sock"))
  }

  @Test(
    "必須引数、値の欠落、未知の引数、別コマンドを拒否する",
    arguments: [
      [String](),
      ["worktree", "open"],
      ["worktree", "open", "--socket", "/socket"],
      ["worktree", "open", "--directory"],
      ["worktree", "open", "--directory", "/path", "--socket"],
      ["worktree", "open", "--directory", "/path", "--unknown"],
      ["worktree", "close", "--directory", "/path"],
      ["project", "open", "--directory", "/path"],
      ["worktree", "open", "--directory", "--socket", "/socket"],
    ]
  )
  func rejectsInvalidArguments(arguments: [String]) {
    guard case .failure = HostControlCommandLine.parse(arguments) else {
      Issue.record("不正な引数を受け付けた: \(arguments)")
      return
    }
  }
}

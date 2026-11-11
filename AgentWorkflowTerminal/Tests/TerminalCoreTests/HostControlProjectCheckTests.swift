import TerminalCore
import Testing

extension HostControlTests {
  @Test("project.check要求をキー順でスラッシュをエスケープせず往復する")
  func checkProjectRequestRoundTrip() throws {
    let request = HostControlRequest.checkProject(directory: "/two words/日本語")
    let line = #"{"command":"project.check","directory":"/two words/日本語","version":1}"#
    #expect(HostControlProtocol.version == 1)
    #expect(Array(HostControlProtocol.encode(request).utf8) == Array(line.utf8))
    #expect(try HostControlProtocol.decodeRequest(line).get() == request)
    #expect(
      try HostControlProtocol.decodeRequest(HostControlProtocol.encode(request)).get() == request)
  }

  @Test(
    "project.checkではfromPaneとpurposeのキーを形式にかかわらず無視する",
    arguments: [
      #""fromPane":"%22","purpose":"概要""#,
      #""fromPane":"invalid","purpose":42"#,
      #""fromPane":42,"purpose":true"#,
      #""fromPane":{},"purpose":[]"#,
      #""fromPane":null,"purpose":null"#,
    ]
  )
  func checkProjectIgnoresWorktreeFields(fields: String) throws {
    let line =
      #"{"command":"project.check","directory":"/path","# + fields + #","version":1}"#
    #expect(
      try HostControlProtocol.decodeRequest(line).get() == .checkProject(directory: "/path"))
  }

  @Test(
    "project.checkのdirectory欠落や文字列以外の値をJSON形式エラーにする",
    arguments: [
      "", #", "directory":null"#, #", "directory":42"#,
      #", "directory":true"#, #", "directory":[]"#, #", "directory":{}"#,
    ]
  )
  func rejectsInvalidCheckProjectDirectory(field: String) {
    let line = #"{"command":"project.check","version":1"# + field + "}"
    #expect(
      HostControlProtocol.decodeRequest(line)
        == .failure(HostControlProtocolError(message: "要求のJSON形式が不正です")))
  }

  @Test("project.checkの未対応versionは既存のエラーにする")
  func rejectsUnsupportedCheckProjectVersion() {
    let line = #"{"command":"project.check","directory":"/path","version":2}"#
    #expect(
      HostControlProtocol.decodeRequest(line)
        == .failure(HostControlProtocolError(message: "未対応のcommandまたはversionです")))
  }

  @Test("登録済み応答をキー順のJSONにして往復する")
  func projectRegisteredRoundTrip() throws {
    let response = HostControlResponse.projectRegistered
    let line = #"{"ok":true,"registered":true,"version":1}"#
    #expect(Array(HostControlProtocol.encode(response).utf8) == Array(line.utf8))
    #expect(try HostControlProtocol.decodeResponse(line).get() == response)
    #expect(
      try HostControlProtocol.decodeResponse(HostControlProtocol.encode(response)).get() == response
    )
  }

  @Test(
    "registeredがfalseまたは真偽値以外ならopenedとしても受け付けない",
    arguments: ["false", "null", "0", "1", #""true""#, #""false""#, "[]", "{}"]
  )
  func rejectsInvalidRegisteredValue(wireValue: String) {
    let line =
      #"{"agentCommand":null,"created":true,"directory":"/path","ok":true,"registered":"#
      + wireValue + #","session":"s","version":1}"#
    #expect(
      HostControlProtocol.decodeResponse(line)
        == .failure(HostControlProtocolError(message: "応答のJSON形式が不正です")))
  }

  @Test("registeredキーがない成功応答は従来のopenedとして読む")
  func responseWithoutRegisteredIsOpened() throws {
    let line =
      #"{"agentCommand":null,"created":true,"directory":"/path","ok":true,"session":"s","version":1}"#
    #expect(
      try HostControlProtocol.decodeResponse(line).get()
        == .opened(
          HostControlOpenedWorktree(
            session: "s", directory: "/path", created: true, agentCommand: nil)))
  }

  @Test("project checkのdirectoryを解釈する")
  func parsesCheckProjectDirectory() throws {
    #expect(
      try HostControlCommandLine.parse(
        ["project", "check", "--directory", "/two words/日本語"]
      ).get() == .checkProject(directory: "/two words/日本語", socket: nil))
  }

  @Test(
    "project checkのsocketをdirectoryの前後どちらでも解釈する",
    arguments: [
      ["--directory", "/path", "--socket", "/private/tmp/host.sock"],
      ["--socket", "/private/tmp/host.sock", "--directory", "/path"],
    ]
  )
  func parsesCheckProjectSocket(options: [String]) throws {
    #expect(
      try HostControlCommandLine.parse(["project", "check"] + options).get()
        == .checkProject(directory: "/path", socket: "/private/tmp/host.sock"))
  }

  @Test(
    "project checkにはdirectoryが必要",
    arguments: [[String](), ["--socket", "/private/tmp/host.sock"]]
  )
  func checkProjectRequiresDirectory(options: [String]) {
    #expect(
      HostControlCommandLine.parse(["project", "check"] + options)
        == .failure(HostControlProtocolError(message: "--directoryが必要です")))
  }

  @Test(
    "project checkはfrom-paneとpurposeと未知の引数を拒否する",
    arguments: ["--from-pane", "--purpose", "--unknown"]
  )
  func rejectsUnsupportedCheckProjectOption(option: String) {
    #expect(
      HostControlCommandLine.parse(["project", "check", "--directory", "/path", option, "%22"])
        == .failure(HostControlProtocolError(message: "不正な引数です: \(option)")))
  }

  @Test(
    "project checkはdirectoryとsocketの2回目の指定を拒否する",
    arguments: ["--directory", "--socket"]
  )
  func rejectsDuplicateCheckProjectOption(option: String) {
    #expect(
      HostControlCommandLine.parse(
        ["project", "check", "--directory", "/path", "--socket", "/s.sock", option, "/other"])
        == .failure(HostControlProtocolError(message: "不正な引数です: \(option)")))
  }

  @Test(
    "project checkは引数の値の欠落を拒否する",
    arguments: ["--directory", "--socket"]
  )
  func rejectsMissingCheckProjectOptionValue(option: String) {
    #expect(
      HostControlCommandLine.parse(["project", "check", option])
        == .failure(HostControlProtocolError(message: "引数の値がありません: \(option)")))
  }

  @Test(
    "project checkは引数の空と--始まりの値を拒否する",
    arguments: ["--directory", "--socket"], ["", "--unknown"]
  )
  func rejectsInvalidCheckProjectOptionValue(option: String, value: String) {
    #expect(
      HostControlCommandLine.parse(["project", "check", option, value])
        == .failure(HostControlProtocolError(message: "不正な引数の値です: \(option)")))
  }

  @Test(
    "未対応の先頭にはworktree openとproject checkを案内する",
    arguments: [
      [String](), ["worktree"], ["project"],
      ["worktree", "close"], ["project", "open"], ["worktree", "check"],
      ["project", "check-other"], ["unknown", "check"],
    ]
  )
  func rejectsUnsupportedCommandWithUsage(arguments: [String]) {
    #expect(
      HostControlCommandLine.parse(arguments)
        == .failure(
          HostControlProtocolError(message: "worktree openまたはproject checkを指定してください")))
  }
}

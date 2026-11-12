import Foundation
import RemoteClient
import Testing

@Suite("接続先設定の検証")
struct RemoteHostSettingsTests {
  @Test("port の両境界と通常値は有効", arguments: [1, 22, 65535])
  func validSettings(port: Int) {
    let settings = RemoteHostSettings(
      host: "mac.ts.net", port: port, user: "user", tmuxPath: "/opt/homebrew/bin/tmux")
    #expect(settings.problems.isEmpty)
  }

  @Test("空でない host・user の前後の空白を拒否する", arguments: [" mac", "mac ", "\tmac\n"])
  func surroundingWhitespace(value: String) {
    let settings = RemoteHostSettings(host: value, port: 22, user: value, tmuxPath: "/tmux")
    #expect(settings.problems.count == 2)
    #expect(settings.problems.contains(.hostHasSurroundingWhitespace))
    #expect(settings.problems.contains(.userHasSurroundingWhitespace))
  }

  @Test("範囲外 port は拒否する", arguments: [Int.min, -1, 0, 65536, Int.max])
  func invalidPort(port: Int) {
    let settings = RemoteHostSettings(
      host: "mac", port: port, user: "user", tmuxPath: "/usr/bin/tmux")
    #expect(settings.problems == [.portOutOfRange])
  }

  @Test("空文字と空白だけの host・user は空とみなす", arguments: ["", " ", " \t\n "])
  func emptyHostAndUser(value: String) {
    let hostSettings = RemoteHostSettings(
      host: value, port: 22, user: "user", tmuxPath: "/tmux")
    #expect(hostSettings.problems == [.emptyHost])
    let userSettings = RemoteHostSettings(
      host: "mac", port: 22, user: value, tmuxPath: "/tmux")
    #expect(userSettings.problems == [.emptyUser])
  }

  @Test("tmuxPath は絶対パスが必要", arguments: ["", "tmux", "~/bin/tmux", " /bin/tmux"])
  func relativeTmuxPath(path: String) {
    let settings = RemoteHostSettings(host: "mac", port: 22, user: "user", tmuxPath: path)
    #expect(settings.problems == [.tmuxPathNotAbsolute])
  }

  @Test("複数の問題をすべて報告する")
  func multipleProblems() {
    let settings = RemoteHostSettings(host: "", port: 0, user: "", tmuxPath: "tmux")
    #expect(settings.problems.count == 4)
    for problem: RemoteHostSettings.Problem in [
      .emptyHost, .portOutOfRange, .emptyUser, .tmuxPathNotAbsolute,
    ] {
      #expect(settings.problems.contains(problem))
    }
  }

  @Test("公開プロパティの変更を検証し、Codable で保持する")
  func mutableAndCodable() throws {
    var settings = RemoteHostSettings(host: "", port: 0, user: "", tmuxPath: "")
    settings.host = "mac"
    settings.port = 2222
    settings.user = "odaryo"
    settings.tmuxPath = "/opt/homebrew/bin/tmux"
    #expect(settings.problems.isEmpty)
    let decoded = try JSONDecoder().decode(
      RemoteHostSettings.self, from: JSONEncoder().encode(settings))
    #expect(decoded == settings)
    #expect(decoded.host == "mac")
    #expect(decoded.port == 2222)
    #expect(decoded.user == "odaryo")
    #expect(decoded.tmuxPath == "/opt/homebrew/bin/tmux")
  }
}

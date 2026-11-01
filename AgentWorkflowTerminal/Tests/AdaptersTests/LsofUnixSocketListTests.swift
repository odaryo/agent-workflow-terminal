import Adapters
import Foundation
import Testing

@Suite("lsof の Unix socket 一覧から listen する process を特定する")
struct LsofUnixSocketListTests {
  @Test("macOS 27 の実測出力から対象 socket の server だけを返す")
  func readsMeasuredOutput() throws {
    #expect(
      LsofUnixSocketList.processIDs(
        listening: measuredOrphanedSocketPath, in: try measuredLsofOutput()) == [15199])
  }

  @Test("listen と accept の2行は同じ PID として返す")
  func deduplicatesServerConnections() {
    let output = "p15199\nf6\nn\(measuredOrphanedSocketPath)\nf7\nn\(measuredOrphanedSocketPath)\n"
    #expect(
      LsofUnixSocketList.processIDs(listening: measuredOrphanedSocketPath, in: output) == [15199])
  }

  @Test(
    "client・別のパス・接頭辞だけ一致するパス・空の出力は一致しない",
    arguments: [
      "p15199\nf6\nn->0x57eff5ebf5b56053\n",
      "p20378\nf6\nn/private/tmp/tmux-501/default\n",
      "p15199\nf6\nn/private/tmp/tmux-501/awtm5001\n",
      "",
    ])
  func rejectsNonMatchingSockets(output: String) {
    #expect(
      LsofUnixSocketList.processIDs(listening: "/private/tmp/tmux-501/awtm500", in: output) == [])
  }

  @Test("複数 PID は重複を除いて数値の昇順で返し、未知の接頭辞は無視する")
  func sortsProcessIDsAndIgnoresOtherFields() {
    let output = """
      p123
      f6
      xunknown
      n/socket
      p20
      ctmux
      n/socket
      p123
      n/socket

      """
    #expect(LsofUnixSocketList.processIDs(listening: "/socket", in: output) == [20, 123])
  }
}

let measuredOrphanedSocketPath = "/private/tmp/tmux-501/awtm50015196"

// Director の実測 (tmux 3.8、macOS 27 標準 lsof)。lsof 自体の版数は計測コメントに無い。
// https://github.com/odaryo/agent-workflow-terminal/issues/500#issuecomment-6561870513
func measuredLsofOutput() throws -> String {
  let url = try #require(
    Bundle.module.url(
      forResource: "lsof-macos-27-unix-tmux-field-pn.txt", withExtension: nil,
      subdirectory: "Fixtures"))
  return try String(contentsOf: url, encoding: .utf8)
}

import RemoteClient
import Testing

@Suite("リモート tmux の POSIX コマンド")
struct RemoteTmuxCommandTests {
  @Test(
    "単一引用で特殊文字も1つの単語にする",
    arguments: [
      ("", "''"),
      ("plain", "'plain'"),
      ("a|b  c ", "'a|b  c '"),
      ("sp 'q", "'sp '\\''q'"),
      ("計測", "'計測'"),
      (#"bs\\x"#, #"'bs\\x'"#),
      ("$HOME; `date` & *", "'$HOME; `date` & *'"),
      ("line\nbreak\t", "'line\nbreak\t'"),
      ("'", "''\\'''"),
    ]
  )
  func shellQuote(value: String, expected: String) {
    #expect(RemoteTmuxCommand.shellQuote(value) == expected)
  }

  @Test(
    "絶対パスを引用し -u と所定の format で一覧を要求する",
    arguments: [
      (
        "/opt/homebrew/bin/tmux",
        "'/opt/homebrew/bin/tmux' -u list-sessions -F "
          + "'#{session_id} #{session_attached} #{session_name}'"
      ),
      (
        "/path with 'quote/tmux",
        "'/path with '\\''quote/tmux' -u list-sessions -F "
          + "'#{session_id} #{session_attached} #{session_name}'"
      ),
    ]
  )
  func listSessions(path: String, expected: String) {
    #expect(RemoteTmuxCommand.listSessions(tmuxPath: path) == expected)
  }

  @Test(
    "名前に = を前置し完全一致の attach を生成する",
    arguments: [
      ("awt-repo-0123abcd-2", "'=awt-repo-0123abcd-2'"),
      ("a|b  c ", "'=a|b  c '"),
      (#"bs\\x"#, #"'=bs\\x'"#),
      ("sp 'q", "'=sp '\\''q'"),
      ("計測", "'=計測'"),
      ("$HOME; `date`", "'=$HOME; `date`'"),
    ]
  )
  func attach(name: String, target: String) {
    #expect(
      RemoteTmuxCommand.attach(tmuxPath: "/opt/homebrew/bin/tmux", sessionName: name)
        == "'/opt/homebrew/bin/tmux' -u attach-session -t " + target)
  }

  @Test("attach も tmuxPath の空白と引用符を保護する")
  func quotedAttachPath() {
    #expect(
      RemoteTmuxCommand.attach(tmuxPath: "/a b/'c/tmux", sessionName: "m806")
        == "'/a b/'\\''c/tmux' -u attach-session -t '=m806'")
  }
}

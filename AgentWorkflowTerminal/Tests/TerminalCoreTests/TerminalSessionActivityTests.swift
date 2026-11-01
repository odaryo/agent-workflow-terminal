import TerminalCore
import Testing

@Suite("タブを閉じる前の非 shell process 判定 (設計書 §3.1)")
struct TerminalSessionActivityTests {
  @Test(
    "shell と login shell だけなら確認不要",
    arguments: ["sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "nu"])
  func shellCommandsDoNotRequireConfirmation(command: String) {
    #expect(!TerminalSessionActivity.hasNonShellProcess(currentCommands: [command]))
    #expect(!TerminalSessionActivity.hasNonShellProcess(currentCommands: ["-" + command]))
  }

  @Test("非 shell と判定不能な空文字は確認が必要", arguments: ["vim", "node", "claude", ""])
  func nonShellCommandsRequireConfirmation(command: String) {
    #expect(TerminalSessionActivity.hasNonShellProcess(currentCommands: [command]))
  }

  @Test("pane が無ければ確認不要")
  func emptyCommandsDoNotRequireConfirmation() {
    #expect(!TerminalSessionActivity.hasNonShellProcess(currentCommands: []))
  }

  @Test("複数 pane が shell だけなら確認不要")
  func multipleShellsDoNotRequireConfirmation() {
    #expect(!TerminalSessionActivity.hasNonShellProcess(currentCommands: ["sh", "-zsh", "fish"]))
  }

  @Test(
    "shell に非 shell が1つでも混ざれば位置によらず確認が必要",
    arguments: [["vim", "zsh"], ["bash", "node", "fish"], ["sh", "claude"], ["-zsh", ""]])
  func mixedCommandsRequireConfirmation(commands: [String]) {
    #expect(TerminalSessionActivity.hasNonShellProcess(currentCommands: commands))
  }
}

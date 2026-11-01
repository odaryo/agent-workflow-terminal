/// - Important: tmux の `pane_current_command` を渡すだけでは足りない。前面のプロセスグループの先頭の
///   名前なので、shell スクリプトや `sh -c '…'` に包まれた処理は `bash` / `sh` と名乗り、shell だけに
///   見える (tmux 3.8 で計測、#455 のレビュー)。入力の作り方は #457 で決める。
public enum TerminalSessionActivity {
  public static func hasNonShellProcess(currentCommands: [String]) -> Bool {
    currentCommands.contains { command in
      let name = command.hasPrefix("-") ? command.dropFirst() : command[...]
      return switch name {
      case "sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "nu": false
      default: true
      }
    }
  }
}

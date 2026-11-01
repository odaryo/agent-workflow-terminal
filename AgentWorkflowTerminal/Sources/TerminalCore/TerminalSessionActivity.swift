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

import Foundation

public enum RemoteTmuxCommand {
  public static func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  // #806 計測2 (tmux 3.8): exec 環境には LANG が無く、-u 無しでは非 ASCII が _ になる。
  public static func listSessions(tmuxPath: String) -> String {
    shellQuote(tmuxPath)
      + " -u list-sessions -F '#{session_id} #{session_attached} #{session_name}'"
  }

  public static func attach(tmuxPath: String, sessionName: String) -> String {
    shellQuote(tmuxPath) + " -u attach-session -t " + shellQuote("=" + sessionName)
  }
}

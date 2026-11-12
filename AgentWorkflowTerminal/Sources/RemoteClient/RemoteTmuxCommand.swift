import Foundation

// Host のログインシェルは POSIX の単一引用を解釈する zsh・bash・sh を前提とする。
public enum RemoteTmuxCommand {
  public static func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  // #806 計測2 (tmux 3.8): exec 環境には LANG が無く、-u 無しでは非 ASCII が _ になる。
  public static func listSessions(tmuxPath: String) -> String {
    shellQuote(tmuxPath)
      + " -u list-sessions -F '#{session_id} #{session_attached} #{session_name}'"
  }

  // #806 spec 2e の tmux 3.8 計測: 名前の : と . は target の区切りに解釈されるため ID で指す。
  // server 再起動で ID が振り直されるので、呼び出し側は attach 直前に毎回 list-sessions から名前で ID を引く。
  public static func attach(tmuxPath: String, sessionID: String) -> String {
    shellQuote(tmuxPath) + " -u attach-session -t " + shellQuote(sessionID)
  }
}

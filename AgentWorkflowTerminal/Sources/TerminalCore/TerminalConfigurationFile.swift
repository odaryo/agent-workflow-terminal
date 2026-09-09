import Foundation

/// 端末設定ファイルの置き場所を決める規則 (設計書 §21.6)。
///
/// - Important: ghostty 本体の default files (`~/.config/ghostty/config` 系および
///   `~/Library/Application Support/com.mitchellh.ghostty/config`) は読まない。
///   libghostty の bundle id はコンパイル時定数なので、default files を読むと
///   **本物の Ghostty.app 向けに書かれた設定**がこの端末へ黙って効く。
public enum TerminalConfigurationFile {
  /// - Parameters:
  ///   - environment: `XDG_CONFIG_HOME` / `HOME` を読む。`ProcessInfo` をここで直接
  ///     触らないのは、`TerminalCore` を外界に依存させないため。
  ///   - fileExists: 同上の理由で `FileManager` を引数で受ける。
  /// - Returns: 設定ファイルが**存在するときだけ**その URL。無ければ `nil`。
  ///   `ghostty_config_load_file` は無いパスを渡しても診断を1本出すだけだが、
  ///   「読む経路がある」ことと「毎回無い物を読みに行く」ことは分ける。
  public static func resolve(
    environment: [String: String],
    fileExists: (String) -> Bool
  ) -> URL? {
    guard let base = configurationHome(environment: environment) else { return nil }
    let url =
      base
      .appendingPathComponent(directoryName, isDirectory: true)
      .appendingPathComponent(fileName, isDirectory: false)
    return fileExists(url.path) ? url : nil
  }

  private static let directoryName = "agent-workflow-terminal"
  private static let fileName = "config"

  private static func configurationHome(environment: [String: String]) -> URL? {
    // ghostty の XDG 解決 (`src/os/xdg.zig`) に合わせる。空文字は未設定と同じ扱いで、
    // 相対パスかどうかは見ない。
    if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
      return URL(fileURLWithPath: xdg, isDirectory: true)
    }
    guard let home = environment["HOME"], !home.isEmpty else { return nil }
    return URL(fileURLWithPath: home, isDirectory: true)
      .appendingPathComponent(".config", isDirectory: true)
  }
}

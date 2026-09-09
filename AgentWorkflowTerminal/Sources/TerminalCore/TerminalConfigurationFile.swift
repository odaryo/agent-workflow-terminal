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
  ///   存在判定をここで済ませるのは、`ghostty_config_load_file` に無いパスを渡すと
  ///   stderr へログが出るだけで**診断列 (`ghostty_config_diagnostics_count`) には
  ///   1本も乗らない**ため (実測)。渡す側が分けなければ、読めなかったことは表に出ない。
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
    // ghostty (`src/os/xdg.zig`) に合わせているのは `XDG_CONFIG_HOME` の空文字を未設定と
    // 同じに扱う点だけで、`HOME` の扱いは意図的に違う。ghostty は `HOME` の空文字を
    // 「設定されている」とみなし、未設定なら `homedir.homeUnix` で OS のホームへ落ちるが、
    // ここはどちらも `nil` にする — `TerminalCore` を `FileManager` へ依存させないため。
    // 解決規則も違い、`URL(fileURLWithPath:)` は tilde を展開し相対パスを cwd で解決するが、
    // ghostty は生の join なので `~/...` のまま open して失敗する。
    if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
      return URL(fileURLWithPath: xdg, isDirectory: true)
    }
    guard let home = environment["HOME"], !home.isEmpty else { return nil }
    return URL(fileURLWithPath: home, isDirectory: true)
      .appendingPathComponent(".config", isDirectory: true)
  }
}

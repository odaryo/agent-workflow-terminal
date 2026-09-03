import Foundation

/// `TerminalRendererConfiguration.command` の符号化規則を、プロセスや UI に依存しない
/// 純粋関数として共有するため TerminalCore に置く。
///
/// libghostty v1.3.1 は macOS で `/usr/bin/login [-q] -flp <user> /bin/bash
/// --noprofile --norc -c "exec -l <command>"` を介して実行する。`exec -l` は復元した
/// argv の分割規則を変えず、argv[0] の先頭に `-` を付ける。
public enum POSIXShellCommandLine {
  public static func joined(_ argv: [String]) -> String {
    argv.map { argument in
      "'\(argument.replacingOccurrences(of: "'", with: "'\\''"))'"
    }.joined(separator: " ")
  }
}

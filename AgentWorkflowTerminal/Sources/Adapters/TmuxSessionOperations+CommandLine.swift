import Foundation
import TerminalCore

extension TmuxSessionOperations {
  public func typeCommandLine(
    _ commandLine: String, into session: TmuxSessionName
  ) async throws(TmuxSessionOperationError) {
    guard
      !commandLine.unicodeScalars.allSatisfy({
        $0.properties.isWhitespace || $0.properties.isDefaultIgnorableCodePoint
      }),
      !commandLine.unicodeScalars.contains(where: {
        $0.properties.generalCategory == .control || $0.value == 0x2028 || $0.value == 0x2029
      })
    else {
      throw .invalidCommandLine(commandLine)
    }

    let target = "=\(session.rawValue):"
    // tmux 3.8 では `-l` の値の末尾 `;` がコマンド区切りとして消えるため、UTF-8 を
    // `-H` で送る。隔離 server の raw PTY で末尾 `;`・`\`・日本語・`#{host}` の一致を実測済み。
    // 文字列と CR を別の呼び出しにすると他の入力が挟まる (tmux 3.8 実測: 30回中21回) ため、
    // 末尾の CR まで1回で送る。
    let bytes = commandLine.utf8.map { String(format: "%02x", $0) }
    _ = try await run(["send-keys", "-t", target, "-H"] + bytes + ["0d"], session: session)
  }
}

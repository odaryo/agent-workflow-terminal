import Adapters
import Foundation

enum ToolVersionWarnings {
  static func tmux(_ result: Result<TmuxVersionSupport, TmuxRunnerError>) -> String? {
    switch result {
    case .success(.supported):
      return nil
    case .success(.unsupported(let version, let minimum)):
      return "tmux \(version) はサポート下限の \(minimum) より古いため、表示や操作が正しく動かないことがあります。"
        + "tmux を更新してください (Homebrew では `brew upgrade tmux`)。"
    case .success(.supportedWithWarnings(let version, let warnings)):
      guard warnings.contains(.zeroWidthJoinerGraphemeWidth) else { return nil }
      return "tmux \(version) では、ZWJ を含む絵文字 (👨‍👩‍👧‍👦 など) の表示幅がずれることがあります。"
        + "3.5 以降で改善しています。機能の制限はありません。"
    case .success(.unknown(let rawOutput)):
      return "tmux の版数を解釈できませんでした (`tmux -V` の出力: \(summarize(rawOutput)))。"
        + "対応している版かどうかは確かめられていません。"
    case .failure(let error):
      return "tmux の版数を確かめられませんでした: \(error)"
    }
  }

  static func git(_ result: Result<GitVersionSupport, GitVersionDetectionError>) -> String? {
    switch result {
    case .success(.supported):
      return nil
    case .success(.unsupported(let version, let minimum)):
      return "git \(version) はサポート下限の \(minimum) より古いため、Diff や File Browser が正しく動かないことがあります。"
        + "git を更新してください。"
    case .success(.unknown(let rawOutput)):
      return "git の版数を解釈できませんでした (`git --version` の出力: \(summarize(rawOutput)))。"
        + "対応している版かどうかは確かめられていません。"
    case .failure(.binaryNotFound(let candidates)):
      return "git 実行ファイルが見つかりません。探した場所: \(candidates.map(\.path).joined(separator: "、"))。"
    case .failure(let error):
      return "git の版数を確かめられませんでした: \(error)"
    }
  }

  private static func summarize(_ rawOutput: String) -> String {
    let output = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
      .map { $0.isNewline ? " " : String($0) }.joined()
    return output.count > 80 ? String(output.prefix(80)) + "…" : output
  }
}

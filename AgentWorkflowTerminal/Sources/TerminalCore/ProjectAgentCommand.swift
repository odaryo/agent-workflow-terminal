import Foundation

public enum ProjectAgentCommandError: Error, Sendable, Equatable {
  case containsControlCharacter
  case tooLong(maximumUTF8Bytes: Int)
}

public enum ProjectAgentCommand {
  public static let maximumUTF8Bytes = 150

  /// 空白だけなら nil (未設定)。前後の空白と改行は除く。
  /// 除いた後に制御文字 (改行・CR・タブ・NUL を含む、Unicode の Cc) があれば失敗。
  public static func normalized(_ input: String) -> Result<String?, ProjectAgentCommandError> {
    let command = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !command.isEmpty else { return .success(nil) }
    guard !command.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
    else {
      return .failure(.containsControlCharacter)
    }
    guard command.utf8.count <= maximumUTF8Bytes else {
      return .failure(.tooLong(maximumUTF8Bytes: maximumUTF8Bytes))
    }
    return .success(command)
  }
}

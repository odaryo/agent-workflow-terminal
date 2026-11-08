import Foundation

public enum ProjectAgentCommandError: Error, Sendable, Equatable {
  case containsControlCharacter
  case tooLong(maximumUTF8Bytes: Int)
}

public enum ProjectAgentCommand {
  public static let maximumUTF8Bytes = 150

  /// 空白と既定で無視される文字だけなら nil (未設定)。
  /// 内部の Unicode Cc 制御文字・行区切り・段落区切りは失敗。
  public static func normalized(_ input: String) -> Result<String?, ProjectAgentCommandError> {
    let isTrimmable: (Unicode.Scalar) -> Bool = {
      $0.properties.isWhitespace || $0.properties.isDefaultIgnorableCodePoint
    }
    let scalars = input.unicodeScalars.drop(while: isTrimmable)
      .reversed().drop(while: isTrimmable).reversed()
    let command = String(String.UnicodeScalarView(scalars))
    guard !command.isEmpty else { return .success(nil) }
    guard
      !command.unicodeScalars.contains(where: {
        $0.properties.generalCategory == .control || $0.value == 0x2028 || $0.value == 0x2029
      })
    else {
      return .failure(.containsControlCharacter)
    }
    guard command.utf8.count <= maximumUTF8Bytes else {
      return .failure(.tooLong(maximumUTF8Bytes: maximumUTF8Bytes))
    }
    return .success(command)
  }
}

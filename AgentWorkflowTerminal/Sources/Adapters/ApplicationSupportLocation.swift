import Foundation

/// 既定の保存先 `~/Library/Application Support/AgentWorkflowTerminal/` は設計書 §22.1 で確定しており、
/// 変更しない。Issue #534 の隔離起動では、その親ディレクトリだけを明示的に上書きする。
public enum ApplicationSupportLocation {
  public static let overrideEnvironmentKey = "AWT_APPLICATION_SUPPORT_DIR"

  public enum Resolution: Sendable, Equatable {
    /// `nil` は FileManager から既定の Application Support を取得できなかったことを表す。
    case standard(URL?)
    case overridden(URL)
    /// 既定へ戻すと、隔離したつもりの起動が実ユーザーのデータを読み書きしてしまうため、
    /// 呼び出し側は保存先を推測せず、保存を止める必要がある。
    case invalid(value: String)
  }

  public static func resolve(environment: [String: String], standard: URL?) -> Resolution {
    guard let value = environment[overrideEnvironmentKey], !value.isEmpty else {
      return .standard(standard)
    }
    guard value.hasPrefix("/") else {
      return .invalid(value: value)
    }
    return .overridden(URL(fileURLWithPath: value, isDirectory: true))
  }
}

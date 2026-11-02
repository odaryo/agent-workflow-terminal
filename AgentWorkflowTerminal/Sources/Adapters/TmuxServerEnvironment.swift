/// 専用 socket の指定は開発中の UI 確認の起動に限る例外であり、製品の既定は変更しない
/// (設計書 §4.1、Issue #535)。不正値を既定 server へ倒すと、隔離のつもりの起動が
/// ユーザーの session へ届くため、呼び出し側は `invalid` なら tmux を使わずに起動する。
public enum TmuxServerEnvironment {
  public static let socketNameKey = "AWT_TMUX_SOCKET_NAME"

  public enum Resolution: Sendable, Equatable {
    case server(TmuxServer)
    case invalid(value: String)
  }

  public static func resolve(environment: [String: String]) -> Resolution {
    guard let value = environment[socketNameKey], !value.isEmpty else {
      return .server(.userDefault)
    }

    // socket のパス上限103バイトに対して名前を64バイトに抑える (Issue #512 のレビュー計測)。
    guard value.utf8.count <= 64,
      value != "default", value != ".", value != "..",
      value.utf8.allSatisfy({ byte in
        switch byte {
        case 65...90, 97...122, 48...57, 46, 95, 45: true
        default: false
        }
      })
    else {
      return .invalid(value: value)
    }

    return .server(.socketName(value))
  }
}

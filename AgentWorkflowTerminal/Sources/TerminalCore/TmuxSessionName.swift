import CryptoKit
import Foundation

/// 設計書 §3.5 の `awt-<slug>-<安定IDのSHA-256先頭8桁>`。
///
/// - Important: 導出結果はそのまま使い、既存 session と衝突しても連番などで回避しない。
///   同じ安定 ID から常に同じ名前が出ることが、再起動後の Resume (§3.3) の前提であるため。
///   ユーザー自身の session と名前空間を共有する (§4.1) 中での衝突回避は、この規則
///   そのものが担う。
/// - Important: 生成名に `.` と `:` は現れない。tmux 3.4 の実測では session 名の `.` と `:` は
///   どちらも `_` へ置換されて格納されるため `a.b` と `a:b` が同一名へ衝突し、さらに
///   `has-session -t "=a.b"` は `.` を window 指定と解釈するため完全一致でも引けない。
/// - Note: 作業ツリーのパスも branch 名も導出に使わない。安定 ID だけに閉じるのは、名前の
///   決定性が Resume (§3.3) の前提だからである。作業ツリーの basename を使うと、安定 ID が
///   不変であるはずの `git worktree move` で名前が変わり、同じ worktree へ二重に session を
///   作ってしまう。
/// - Note: 代償として、slug は `git worktree move` の後に実際のディレクトリ名とずれ得る。
///   管理ディレクトリ名は移動しても作成時の名前のままだからである (git 2.50.1 で実測)。
///   可読性より決定性を優先した帰結として受け入れる。
public struct TmuxSessionName: Sendable, Hashable {
  public let rawValue: String

  public init(identity: WorktreeIdentity) {
    self.rawValue = "awt-\(Self.slug(for: identity))-\(Self.hash8(of: identity))"
  }

  /// 識別は hash が担い、slug は人が `list-sessions` を読むためだけのものなので、
  /// 長さで可読性を損なわないところで切る。
  private static let slugCharacterLimit = 32

  /// 安定 ID にパス要素が1つも無いときに使う。空 slug は `awt--<hash>` という読みづらい
  /// 名前になるため。
  private static let emptySlugFallback = "worktree"

  /// Project Root の安定 ID は `<repo>/.git` なので、そのままでは全 Project の Project Root が
  /// `awt-_git-<hash>` になり `list-sessions` から読めない。bare repository の `<repo>.git` は
  /// `repo_git` になってこの値と一致しないため、分岐に入らない (git 2.50.1 で実測)。
  private static let projectRootSlugMarker = "_git"

  private static let hashByteCount = 4

  private static func slug(for identity: WorktreeIdentity) -> String {
    let components = identity.rawValue.split(separator: "/").map { normalize($0) }
    guard let last = components.last else { return emptySlugFallback }

    let selected = last == projectRootSlugMarker ? (components.dropLast().last ?? last) : last
    return String(selected.prefix(slugCharacterLimit))
  }

  private static func normalize(_ pathComponent: Substring) -> String {
    String(pathComponent.map { isAllowedInSlug($0) ? $0 : "_" })
  }

  /// 判定は Character 単位。複数スカラーからなる書記素はまとめて1文字の `_` になる。
  private static func isAllowedInSlug(_ character: Character) -> Bool {
    guard character.isASCII else { return false }
    return character.isLetter || character.isNumber || character == "_" || character == "-"
  }

  private static func hash8(of identity: WorktreeIdentity) -> String {
    let digest = SHA256.hash(data: Data(identity.rawValue.utf8))
    return digest.prefix(hashByteCount).map { String(format: "%02x", $0) }.joined()
  }
}

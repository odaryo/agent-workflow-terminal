import Foundation

public enum WorktreePathScope {
  /// 外部 CLI が返した絶対パスを worktree 相対へ変換する。root 自身と root の外は `nil`。
  ///
  /// §8.1「検索範囲は常に現在の worktree 内だけ」を、CLI へ渡した引数だけに預けない。
  /// 比較は NFC へ寄せたスカラ列の上で行う: ripgrep はファイルシステム上のバイト列を
  /// そのまま返すので、macOS で NFD のパスと、こちらが組み立てた NFC の root が
  /// 食い違い得る (`WorktreeRelativePath` と同じ理由)。
  public static func relativePath(
    forAbsolutePath absolutePath: String,
    underRoot root: String
  ) -> WorktreeRelativePath? {
    let path = Array(absolutePath.precomposedStringWithCanonicalMapping.unicodeScalars)
    var prefix = Array(root.precomposedStringWithCanonicalMapping.unicodeScalars)
    guard prefix.first?.value == 0x2F, path.first?.value == 0x2F else { return nil }
    while prefix.count > 1, prefix.last?.value == 0x2F { prefix.removeLast() }
    guard path.count > prefix.count else { return nil }
    guard path.prefix(prefix.count).elementsEqual(prefix, by: { $0.value == $1.value }) else {
      return nil
    }
    // root が "/" のときは prefix 自身が区切りなので、余分な "/" を要求しない。
    let separatorCount = prefix.count == 1 ? 0 : 1
    guard separatorCount == 0 || path[prefix.count].value == 0x2F else { return nil }
    let remainder = path.dropFirst(prefix.count + separatorCount)
    var scalars = String.UnicodeScalarView()
    scalars.append(contentsOf: remainder)
    return WorktreeRelativePath(String(scalars))
  }
}

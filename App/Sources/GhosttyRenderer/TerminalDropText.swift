import Foundation

enum TerminalDropText {
  static func text(for urls: [URL]) -> String? {
    let metacharacters = Set(" \\'\"`$!#&;|*?()[]{}<>~=%^".unicodeScalars)
    let paths = urls.filter(\.isFileURL).compactMap { url -> String? in
      let path = url.path
      guard !path.unicodeScalars.contains(where: { $0.value <= 31 || $0.value == 127 }) else {
        return nil
      }
      // Why not 単一引用符: Agent の画像パス認識と互換性を持たせるため、Terminal.app と
      // 同じ backslash 形式を使う。実際の認識可否は UI 確認で検証する。
      return path.unicodeScalars.map { scalar in
        (metacharacters.contains(scalar) ? "\\" : "") + String(scalar)
      }.joined()
    }
    return paths.isEmpty ? nil : paths.joined(separator: " ")
  }
}

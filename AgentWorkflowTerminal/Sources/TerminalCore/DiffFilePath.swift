/// diff のパス比較。
///
/// `String` の `==` と `<` は Unicode の正準等価で見るため、NFC の `é.swift` と NFD の `é.swift`
/// を同じ文字列と答える (実測: `==` が `true`、UTF-8 は `[195,169,…]` と `[101,204,129,…]`)。
/// git は同一 tree に現れた両表記をそのまま出力し、diff には別ファイルとして並ぶため、
/// 丸めると別ファイルの行を掴む。**同値判定と順序判定の両方**をバイト列へ揃えないと、
/// 順序に循環ができて並びが入力順に依存する。粒度を揃える理由は `WorktreeIdentity` と同じ。
enum DiffFilePath {
  static func isSame(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.elementsEqual(rhs.utf8)
  }

  static func precedes(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
  }
}

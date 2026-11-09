extension TmuxSessionOperations {
  /// アプリ管理の名前は `[A-Za-z0-9_-]` だけで置換と復号で変わらないので、復号できない行を飛ばしても
  /// 管理下の session を見落とさない (Issue #638)。
  static func parseSessionNames(output: String) -> TmuxSessionNameList {
    var names: [String] = []
    var undecodableLineCount = 0
    for line in output.split(separator: "\n") {
      do {
        names.append(try TmuxListPanes.decodeSessionName(String(line)))
      } catch {
        undecodableLineCount += 1
      }
    }
    return TmuxSessionNameList(names: names, undecodableLineCount: undecodableLineCount)
  }
}

extension TmuxSessionOperations {
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

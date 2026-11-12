enum TruncatedDiffPatch {
  static func completeRecords(in output: String) -> (patch: String, firstOmittedPath: String?) {
    var lastRecordStart: String.Index?
    var lineStart = output.startIndex
    while lineStart < output.endIndex {
      let lineEnd = output.utf8[lineStart...].firstIndex(of: 0x0A) ?? output.endIndex
      if DiffRecord.startsRecord(output[lineStart..<lineEnd]) { lastRecordStart = lineStart }
      guard lineEnd < output.endIndex else { break }
      lineStart = output.utf8.index(after: lineEnd)
    }
    guard let lastRecordStart else { return ("", nil) }

    // hunk が完結していても、続く hunk が失われた可能性があるので最後のレコードは残さない。
    var headerEnd = lastRecordStart
    while headerEnd < output.endIndex {
      let lineEnd = output.utf8[headerEnd...].firstIndex(of: 0x0A) ?? output.endIndex
      if output[headerEnd..<lineEnd].hasPrefix("@@") { break }
      // 途中で切れた header 行をパーサに渡すと、短縮されたパスを完全なパスと誤認し得る。
      guard lineEnd < output.endIndex else { break }
      headerEnd = output.utf8.index(after: lineEnd)
    }
    let header = String(output[lastRecordStart..<headerEnd])
    let parsed = UnifiedDiffPatch.parse(output: header)
    return (
      String(output[..<lastRecordStart]),
      parsed.files.count == 1 ? parsed.files.first?.path : nil
    )
  }
}

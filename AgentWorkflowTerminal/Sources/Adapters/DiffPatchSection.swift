import TerminalCore

struct DiffPatchSection {
  let section: DiffOriginSection
  let failures: [UnifiedDiffParseFailure]

  init(output: ProcessRunOutput, origin: DiffChangeOrigin) {
    let text: String
    let truncation: DiffSectionTruncation?
    switch output {
    case .completed(let result):
      text = result.stdout
      truncation = nil
    case .truncated(let stdout, _, let limit):
      let complete = TruncatedDiffPatch.completeRecords(in: stdout)
      text = complete.patch
      truncation = DiffSectionTruncation(
        outputLimit: limit, firstOmittedPath: complete.firstOmittedPath)
    }
    let parsed = UnifiedDiffPatch.parse(output: text)
    section = DiffOriginSection(
      origin: origin, files: parsed.files, unparsedRecordCount: parsed.failures.count,
      truncation: truncation)
    failures = parsed.failures
  }
}

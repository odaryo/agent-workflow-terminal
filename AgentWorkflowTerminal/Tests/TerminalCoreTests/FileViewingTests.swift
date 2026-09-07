import TerminalCore
import Testing

@Suite("ファイル表示判定 (設計書 §7.2)")
struct FileViewingTests {
  @Test("既定の閾値を公開する")
  func defaultThresholds() {
    #expect(FileViewThresholds.default.maximumByteCount == 1_048_576)
    #expect(FileViewThresholds.default.maximumLineCount == 50_000)
  }

  @Test("先頭 8 KiB に NUL があればバイナリと判定する")
  func detectsBinaryContent() {
    #expect(BinaryFileDetection.sampleByteCount == 8_192)
    #expect(BinaryFileDetection.isBinary(sample: [] as [UInt8]) == false)
    #expect(BinaryFileDetection.isBinary(sample: [65, 0, 66]))
  }

  @Test("NUL の位置は先頭 8 KiB だけを判定対象にする")
  func limitsBinaryDetectionToSample() {
    var atLastSampleByte = Array(repeating: UInt8(65), count: 8_192)
    atLastSampleByte[8_191] = 0
    #expect(BinaryFileDetection.isBinary(sample: atLastSampleByte))

    var afterSample = Array(repeating: UInt8(65), count: 8_193)
    afterSample[8_192] = 0
    #expect(BinaryFileDetection.isBinary(sample: afterSample) == false)
  }

  @Test("バイナリかつ大容量なら両方の理由を安定した順で返す")
  func returnsAllWarningReasonsInStableOrder() throws {
    let decision = FileOpenDecision.decide(
      observation: FileViewObservation(byteCount: 101, isBinary: true, lineCount: nil),
      thresholds: FileViewThresholds(maximumByteCount: 100, maximumLineCount: 10)
    )

    let reasons = try #require(decision.confirmationReasons)
    #expect(
      reasons.elements == [
        .binary(byteCount: 101),
        .byteCount(actual: 101, maximum: 100),
      ])
  }

  @Test("大容量かつ行数超過なら両方の理由を安定した順で返す")
  func returnsObservedSizeReasonsInStableOrder() throws {
    let decision = FileOpenDecision.decide(
      observation: FileViewObservation(byteCount: 101, isBinary: false, lineCount: 11),
      thresholds: FileViewThresholds(maximumByteCount: 100, maximumLineCount: 10)
    )

    let reasons = try #require(decision.confirmationReasons)
    #expect(
      reasons.elements == [
        .byteCount(actual: 101, maximum: 100),
        .lineCount(actual: 11, maximum: 10),
      ])
  }

  @Test("閾値ちょうどはそのまま表示する")
  func allowsValuesAtThresholds() {
    let decision = FileOpenDecision.decide(
      observation: FileViewObservation(byteCount: 100, isBinary: false, lineCount: 10),
      thresholds: FileViewThresholds(maximumByteCount: 100, maximumLineCount: 10)
    )

    #expect(decision == .display)
  }

  @Test("未観測の行数から理由を作らない")
  func doesNotInventMissingLineCount() throws {
    let decision = FileOpenDecision.decide(
      observation: FileViewObservation(byteCount: 101, isBinary: false, lineCount: nil),
      thresholds: FileViewThresholds(maximumByteCount: 100, maximumLineCount: 10)
    )

    let reasons = try #require(decision.confirmationReasons)
    #expect(reasons.elements == [.byteCount(actual: 101, maximum: 100)])
  }

  @Test("警告理由の非空型は先頭要素を必須とする")
  func confirmationReasonsRequireFirstElement() {
    let reasons = FileOpenConfirmationReasons(first: .binary(byteCount: 1))
    #expect(reasons.elements == [.binary(byteCount: 1)])
  }
}

import TerminalCore
import Testing

@Suite("ファイル表示判定 (設計書 §7.2)")
struct FileViewingTests {
  @Test("既定の閾値を公開する")
  func defaultThresholds() {
    #expect(FileViewThresholds.default.maximumByteCount == 1_048_576)
    #expect(FileViewThresholds.default.maximumLineCount == 50_000)
    #expect(FileViewThresholds.default.absoluteMaximumByteCount == 16_777_216)
  }

  @Test("先頭 8 KiB に NUL があればバイナリと判定する")
  func detectsBinaryContent() throws {
    #expect(BinaryFileDetection.sampleByteCount == 8_192)
    let empty = try #require(BinaryFileSample(bytes: [], fileByteCount: 0))
    let binary = try #require(BinaryFileSample(bytes: [65, 0, 66], fileByteCount: 3))
    #expect(BinaryFileDetection.isBinary(sample: empty) == false)
    #expect(BinaryFileDetection.isBinary(sample: binary))
  }

  @Test("NUL の位置は先頭 8 KiB だけを判定対象にする")
  func limitsBinaryDetectionToSample() throws {
    var atLastSampleByte = Array(repeating: UInt8(65), count: 8_192)
    atLastSampleByte[8_191] = 0
    let completeSample = try #require(
      BinaryFileSample(bytes: atLastSampleByte, fileByteCount: 8_193))
    #expect(BinaryFileDetection.isBinary(sample: completeSample))

    var afterSample = Array(repeating: UInt8(65), count: 8_193)
    afterSample[8_192] = 0
    let truncatedSample = try #require(
      BinaryFileSample(bytes: Array(afterSample.prefix(8_192)), fileByteCount: 8_193))
    #expect(BinaryFileDetection.isBinary(sample: truncatedSample) == false)
  }

  @Test("ファイルサイズと8 KiBの小さい方を満たさないサンプルを拒否する")
  func rejectsIncompleteBinarySample() {
    #expect(
      BinaryFileSample(bytes: Array(repeating: 65, count: 4_096), fileByteCount: 8_192) == nil)
    #expect(BinaryFileSample(bytes: [65, 66], fileByteCount: 3) == nil)
  }

  @Test("バイナリかつ大容量なら両方の理由を安定した順で返す")
  func returnsAllWarningReasonsInStableOrder() throws {
    let decision = FileOpenDecision.decide(
      observation: .binary(byteCount: 101),
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
      observation: .text(byteCount: 101, lineCount: 11),
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
      observation: .text(byteCount: 100, lineCount: 10),
      thresholds: FileViewThresholds(maximumByteCount: 100, maximumLineCount: 10)
    )

    #expect(decision == .display)
  }

  @Test("未観測の行数から理由を作らない")
  func doesNotInventMissingLineCount() throws {
    let decision = FileOpenDecision.decide(
      observation: .text(byteCount: 101, lineCount: nil),
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

import Foundation
import TerminalCore

public enum FileContentReaderError: Error, Sendable, Equatable {
  case invalidByteCount(String)
  case readFailed(String)
  case incompleteSample(expected: Int, actual: Int)
  case fileChanged(expected: Int, actual: Int)
}

public struct FileContentReadResult: Sendable, Equatable {
  public let observation: FileViewObservation
  public let decision: FileOpenDecision
  public let text: String?
}

public struct FileContentReader: Sendable {
  public init() {}

  public func read(
    url: URL,
    thresholds: FileViewThresholds = .default
  ) throws -> FileContentReadResult {
    let byteCount = try byteCount(of: url)

    do {
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      let sampleCount = min(byteCount, BinaryFileDetection.sampleByteCount)
      let sampleData = try handle.read(upToCount: sampleCount) ?? Data()
      guard sampleData.count == sampleCount else {
        throw FileContentReaderError.incompleteSample(
          expected: sampleCount, actual: sampleData.count)
      }
      guard let sample = BinaryFileSample(bytes: Array(sampleData), fileByteCount: byteCount) else {
        throw FileContentReaderError.incompleteSample(
          expected: sampleCount, actual: sampleData.count)
      }
      if BinaryFileDetection.isBinary(sample: sample) {
        return result(observation: .binary(byteCount: byteCount), text: nil, thresholds: thresholds)
      }
      if byteCount > thresholds.maximumByteCount {
        return result(
          observation: .text(byteCount: byteCount, lineCount: nil), text: nil,
          thresholds: thresholds)
      }

      return try readText(
        from: handle,
        sampleData: sampleData,
        byteCount: byteCount,
        thresholds: thresholds)
    } catch let error as FileContentReaderError {
      throw error
    } catch {
      throw FileContentReaderError.readFailed(url.path)
    }
  }

  private func byteCount(of url: URL) throws(FileContentReaderError) -> Int {
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      guard let size = attributes[.size] as? NSNumber else {
        throw FileContentReaderError.invalidByteCount(url.path)
      }
      return size.intValue
    } catch let error as FileContentReaderError {
      throw error
    } catch {
      throw FileContentReaderError.readFailed(url.path)
    }
  }

  private func readText(
    from handle: FileHandle,
    sampleData: Data,
    byteCount: Int,
    thresholds: FileViewThresholds
  ) throws -> FileContentReadResult {
    let remaining = try handle.readToEnd() ?? Data()
    let data = sampleData + remaining
    guard data.count == byteCount else {
      throw FileContentReaderError.fileChanged(expected: byteCount, actual: data.count)
    }
    // 設計書に文字コード推測の要求が無いため、不正 UTF-8 は別 encoding ではなく binary とする。
    guard let text = String(data: data, encoding: .utf8) else {
      return result(observation: .binary(byteCount: byteCount), text: nil, thresholds: thresholds)
    }
    let lineCount =
      data.reduce(into: 0) { count, byte in
        if byte == 0x0A { count += 1 }
      } + (data.isEmpty || data.last == 0x0A ? 0 : 1)
    let observation = FileViewObservation.text(byteCount: byteCount, lineCount: lineCount)
    let decision = FileOpenDecision.decide(observation: observation, thresholds: thresholds)
    return FileContentReadResult(
      observation: observation,
      decision: decision,
      text: decision == .display ? text : nil)
  }

  private func result(
    observation: FileViewObservation,
    text: String?,
    thresholds: FileViewThresholds
  ) -> FileContentReadResult {
    FileContentReadResult(
      observation: observation,
      decision: FileOpenDecision.decide(observation: observation, thresholds: thresholds),
      text: text)
  }
}

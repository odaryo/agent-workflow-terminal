public struct FileViewThresholds: Sendable, Hashable {
  public let maximumByteCount: Int
  public let maximumLineCount: Int

  public static let `default` = Self(
    maximumByteCount: 1_048_576,
    maximumLineCount: 50_000
  )

  public init(maximumByteCount: Int, maximumLineCount: Int) {
    self.maximumByteCount = maximumByteCount
    self.maximumLineCount = maximumLineCount
  }
}

public enum BinaryFileDetection {
  public static let sampleByteCount = 8_192

  public static func isBinary(sample: BinaryFileSample) -> Bool {
    sample.bytes.contains(0)
  }
}

public struct BinaryFileSample: Sendable, Hashable {
  fileprivate let bytes: [UInt8]

  /// 呼び出し側はファイル先頭から `min(fileByteCount, 8_192)` バイトを読み切って渡す。
  public init?(bytes: [UInt8], fileByteCount: Int) {
    guard fileByteCount >= 0, bytes.count == min(fileByteCount, BinaryFileDetection.sampleByteCount)
    else { return nil }
    self.bytes = bytes
  }
}

public enum FileViewObservation: Sendable, Hashable {
  case binary(byteCount: Int)
  case text(byteCount: Int, lineCount: Int?)

  fileprivate var byteCount: Int {
    switch self {
    case .binary(let byteCount), .text(let byteCount, _):
      byteCount
    }
  }

  fileprivate var isBinary: Bool {
    if case .binary = self { return true }
    return false
  }

  fileprivate var lineCount: Int? {
    if case .text(_, let lineCount) = self { return lineCount }
    return nil
  }
}

public enum FileOpenConfirmationReason: Sendable, Hashable {
  case binary(byteCount: Int)
  case byteCount(actual: Int, maximum: Int)
  case lineCount(actual: Int, maximum: Int)
}

public struct FileOpenConfirmationReasons: Sendable, Hashable {
  public let elements: [FileOpenConfirmationReason]

  public init(
    first: FileOpenConfirmationReason,
    remaining: [FileOpenConfirmationReason] = []
  ) {
    elements = [first] + remaining
  }
}

public enum FileOpenDecision: Sendable, Hashable {
  case display
  case confirm(FileOpenConfirmationReasons)

  public var confirmationReasons: FileOpenConfirmationReasons? {
    switch self {
    case .display:
      nil
    case .confirm(let reasons):
      reasons
    }
  }

  public static func decide(
    observation: FileViewObservation,
    thresholds: FileViewThresholds = .default
  ) -> Self {
    var reasons: [FileOpenConfirmationReason] = []
    if observation.isBinary {
      reasons.append(.binary(byteCount: observation.byteCount))
    }
    if observation.byteCount > thresholds.maximumByteCount {
      reasons.append(
        .byteCount(
          actual: observation.byteCount,
          maximum: thresholds.maximumByteCount
        ))
    }
    if let lineCount = observation.lineCount,
      lineCount > thresholds.maximumLineCount
    {
      reasons.append(
        .lineCount(actual: lineCount, maximum: thresholds.maximumLineCount))
    }

    guard let first = reasons.first else { return .display }
    return .confirm(
      FileOpenConfirmationReasons(first: first, remaining: Array(reasons.dropFirst())))
  }
}

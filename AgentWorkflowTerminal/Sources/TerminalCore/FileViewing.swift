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

  public static func isBinary<Bytes: Collection>(sample: Bytes) -> Bool
  where Bytes.Element == UInt8 {
    sample.prefix(sampleByteCount).contains(0)
  }
}

public struct FileViewObservation: Sendable, Hashable {
  public let byteCount: Int
  public let isBinary: Bool
  public let lineCount: Int?

  public init(byteCount: Int, isBinary: Bool, lineCount: Int?) {
    self.byteCount = byteCount
    self.isBinary = isBinary
    self.lineCount = lineCount
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

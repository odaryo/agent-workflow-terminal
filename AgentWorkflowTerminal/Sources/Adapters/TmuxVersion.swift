import Foundation

public struct TmuxVersion: Sendable, Equatable, Hashable, Comparable, CustomStringConvertible {
  public static let minimumSupported = Self(major: 3, minor: 4)
  // tmux commit 89c1c43ef（3.4→3.5 の開発期間）と Spikes/gate1/README.md §10.3 の実測に基づく。
  public static let zeroWidthJoinerFixed = Self(major: 3, minor: 5)

  public let major: Int
  public let minor: Int
  public let suffix: String

  public var description: String {
    "\(major).\(minor)\(suffix)"
  }

  public init(major: Int, minor: Int, suffix: String = "") {
    self.major = major
    self.minor = minor
    self.suffix = suffix
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.major != rhs.major {
      return lhs.major < rhs.major
    }
    if lhs.minor != rhs.minor {
      return lhs.minor < rhs.minor
    }
    return lhs.suffix < rhs.suffix
  }

  public static func parse(versionOutput: String) -> TmuxVersionParseResult {
    let trimmedOutput = versionOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    let prefix = "tmux "
    guard trimmedOutput.hasPrefix(prefix) else {
      return .unparsable(versionOutput)
    }

    let version = String(trimmedOutput.dropFirst(prefix.count))
    if version.hasPrefix("next-") {
      // next-X.Y はリリース版 X.Y の直前であり、ZWJ 修正を含むか版数だけでは判定できない。
      // 観測結果を X.Y へ丸めず unknown へ渡す（設計書 §12.3）。
      return .unparsable(versionOutput)
    }

    let components = version.split(separator: ".", omittingEmptySubsequences: false)
    guard components.count == 2,
      let major = parseASCIIInteger(components[0]),
      let (minor, suffix) = parseMinor(components[1])
    else {
      return .unparsable(versionOutput)
    }

    return .parsed(Self(major: major, minor: minor, suffix: suffix))
  }

  public static func support(for result: TmuxVersionParseResult) -> TmuxVersionSupport {
    switch result {
    case .parsed(let version):
      if version < minimumSupported {
        return .unsupported(version, minimum: minimumSupported)
      }
      if version < zeroWidthJoinerFixed {
        return .supportedWithWarnings(version, [.zeroWidthJoinerGraphemeWidth])
      }
      return .supported(version)
    case .unparsable(let rawOutput):
      // 観測できない版数を既定の支援状態へ丸めない（設計書 §12.3 と同じ方針）。
      return .unknown(rawOutput: rawOutput)
    }
  }

  private static func parseMinor(_ value: Substring) -> (Int, String)? {
    guard let last = value.last else {
      return nil
    }

    let suffix: String
    let digits: Substring
    if last.isASCII, last.isLowercase, last.isLetter {
      suffix = String(last)
      digits = value.dropLast()
    } else {
      suffix = ""
      digits = value
    }

    guard let minor = parseASCIIInteger(digits) else {
      return nil
    }
    return (minor, suffix)
  }

  private static func parseASCIIInteger(_ value: Substring) -> Int? {
    guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }) else {
      return nil
    }
    return Int(value)
  }
}

public enum TmuxVersionParseResult: Sendable, Equatable {
  case parsed(TmuxVersion)
  case unparsable(String)
}

public enum TmuxVersionSupport: Sendable, Equatable {
  case supported(TmuxVersion)
  case supportedWithWarnings(TmuxVersion, Set<TmuxVersionWarning>)
  case unsupported(TmuxVersion, minimum: TmuxVersion)
  case unknown(rawOutput: String)
}

public enum TmuxVersionWarning: Sendable, Equatable, Hashable {
  // tmux 3.4 は ZWJ を含む grapheme の表示幅を誤る（Spikes/gate1/README.md §10.3）。
  case zeroWidthJoinerGraphemeWidth
}

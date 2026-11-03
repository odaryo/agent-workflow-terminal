import Foundation

/// 配布元の接尾辞は不揃いなので、サポート下限の比較には数値部分だけを用いる（設計書 §17.3）。
public struct GitVersion: Sendable, Equatable, Hashable, Comparable, CustomStringConvertible {
  public static let minimumSupported = Self(major: 2, minor: 39, patch: 0)

  public let major: Int
  public let minor: Int
  public let patch: Int

  public var description: String { "\(major).\(minor).\(patch)" }

  /// CLI の表記差を持ち込まず、比較する数値を直接指定できるようにする。
  public init(major: Int, minor: Int, patch: Int) {
    self.major = major
    self.minor = minor
    self.patch = patch
  }

  /// 文字列比較では 2.9 が 2.39 より後になるため、各成分を数値として比較する。
  public static func < (lhs: Self, rhs: Self) -> Bool {
    (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
  }

  /// 2.39.0-rc1 は 2.39.0 より前なので、正式版へ丸めると下限の判定を誤る。
  /// `-rc` / `.rc` は解釈不能とし、それ以外の patch 後方は配布元ごとに不揃いなので比較しない。
  /// 上流の GIT-VERSION-GEN の DEF_VER は X.Y.0 の後の開発版を X.Y.GIT と表す。
  public static func parse(versionOutput: String) -> GitVersionParseResult {
    let trimmedOutput = versionOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    let prefix = "git version "
    guard trimmedOutput.hasPrefix(prefix) else {
      return .unparsable(versionOutput)
    }

    let components = trimmedOutput.dropFirst(prefix.count).split(
      separator: ".", maxSplits: 2, omittingEmptySubsequences: false)
    guard components.count >= 2,
      let major = parseASCIIInteger(components[0]),
      let minor = parseASCIIInteger(components[1])
    else {
      return .unparsable(versionOutput)
    }

    var patch = 0
    if components.count == 3 {
      let digits = components[2].prefix { $0.isASCII && $0.isNumber }
      if !digits.isEmpty {
        guard let parsedPatch = parseASCIIInteger(digits) else {
          return .unparsable(versionOutput)
        }
        patch = parsedPatch
      } else if components[2] != "GIT" {
        return .unparsable(versionOutput)
      }
      let suffix = components[2].dropFirst(digits.count)
      guard !suffix.hasPrefix("-rc"), !suffix.hasPrefix(".rc") else {
        return .unparsable(versionOutput)
      }
    }

    return .parsed(Self(major: major, minor: minor, patch: patch))
  }

  /// 解釈不能を対象内・対象外へ丸めず、下限未満も拒否ではなく警告の判断材料にする（設計書 §17.3）。
  public static func support(for result: GitVersionParseResult) -> GitVersionSupport {
    switch result {
    case .parsed(let version):
      if version < minimumSupported {
        return .unsupported(version, minimum: minimumSupported)
      }
      return .supported(version)
    case .unparsable(let rawOutput):
      return .unknown(rawOutput: rawOutput)
    }
  }

  /// Unicode の数字や Int に収まらない値を有効な版数へ丸めないため、変換前にも検査する。
  private static func parseASCIIInteger(_ value: Substring) -> Int? {
    guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }) else {
      return nil
    }
    return Int(value)
  }
}

/// 誤判定の調査に原文が必要なので、解釈不能でも入力を捨てない。
public enum GitVersionParseResult: Sendable, Equatable {
  case parsed(GitVersion)
  case unparsable(String)
}

/// 下限未満と観測不能を分け、どちらも接続拒否の根拠にしない（設計書 §17.3）。
public enum GitVersionSupport: Sendable, Equatable {
  case supported(GitVersion)
  case unsupported(GitVersion, minimum: GitVersion)
  case unknown(rawOutput: String)
}

/// 実行の失敗と版数の解釈不能では対処が異なるため、失敗時の出力と実行層エラーを保持する。
public enum GitVersionDetectionError: Error, Sendable, Equatable {
  case binaryNotFound(candidates: [URL])
  case process(ProcessRunnerError)
  case commandFailed(exitCode: Int32, stdout: String, stderr: String)
}

extension GitVersion {
  /// 実行失敗を unknown に丸めると観測不能の原因を失うため、TmuxRunner.version と同じく投げる（設計書 §12.3）。
  public static func detect(
    executableCandidates: [URL] = GitRunner.defaultExecutableCandidates,
    processRunner: some ProcessRunning, timeout: Duration = .seconds(5)
  ) async throws(GitVersionDetectionError) -> GitVersionSupport {
    try await detect(
      executableCandidates: executableCandidates, processRunner: processRunner, timeout: timeout,
      parentEnvironment: ProcessInfo.processInfo.environment,
      isExecutableFile: { FileManager.default.isExecutableFile(atPath: $0.path) })
  }

  static func detect(
    executableCandidates: [URL], processRunner: some ProcessRunning,
    timeout: Duration = .seconds(5), parentEnvironment: [String: String],
    isExecutableFile: @Sendable (URL) -> Bool
  ) async throws(GitVersionDetectionError) -> GitVersionSupport {
    guard
      let executableURL = GitRunner.resolveExecutable(
        candidates: executableCandidates, isExecutableFile: isExecutableFile)
    else {
      throw .binaryNotFound(candidates: executableCandidates)
    }
    let environment = GitRunner.restrictedEnvironment(parent: parentEnvironment)
    let result: ProcessRunResult
    do {
      result = try await processRunner.run(
        executableURL: executableURL, arguments: ["--version"], environment: environment,
        timeout: timeout)
    } catch {
      throw .process(error)
    }
    guard result.exitCode == 0 else {
      throw .commandFailed(exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr)
    }
    return support(for: parse(versionOutput: result.stdout))
  }
}

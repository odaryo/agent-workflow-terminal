import Foundation

public enum TmuxExecutableResolution: Sendable, Equatable {
  case found(URL, source: Source)
  case overrideNotUsable(path: String, reason: OverrideProblem)
  case notFound(searched: [URL])

  public enum Source: Sendable, Equatable {
    case override
    case defaultCandidate
  }

  public enum OverrideProblem: Sendable, Equatable {
    case notAbsolute
    case notExecutable
  }

  /// 上書きが使えなくても既定候補へ落とさない。ユーザーが明示した tmux と別の版が、
  /// ユーザーの既定 server へ接続するのを防ぐため（設計書 §4.3）。
  /// Settings の入力欄の値をそのまま使い、展開の規則をアプリが持たないため、`~` は展開しない。
  public static func resolve(
    overridePath: String?,
    candidates: [URL] = TmuxRunner.defaultExecutableCandidates,
    isExecutableFile: (String) -> Bool
  ) -> Self {
    if let path = overridePath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
      guard path.hasPrefix("/") else {
        return .overrideNotUsable(path: path, reason: .notAbsolute)
      }
      guard isExecutableFile(path) else {
        return .overrideNotUsable(path: path, reason: .notExecutable)
      }
      return .found(URL(fileURLWithPath: path), source: .override)
    }

    for candidate in candidates where isExecutableFile(candidate.path) {
      return .found(candidate, source: .defaultCandidate)
    }
    return .notFound(searched: candidates)
  }
}

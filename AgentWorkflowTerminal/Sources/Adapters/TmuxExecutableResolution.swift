import Foundation

public enum TmuxExecutableFileKind: Sendable, Equatable {
  /// 実行権のある、ディレクトリでないもの。symlink は辿った先で判定する。
  case executableFile
  case directory
  /// 存在しない・実行権が無い・その他。
  case unusable
}

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
    case isDirectory
    case notExecutable
  }

  /// 上書きが使えなくても既定候補へ落とさない。ユーザーが明示した tmux と別の版が、
  /// ユーザーの既定 server へ接続するのを防ぐため（設計書 §4.3）。
  /// Settings の入力欄の値をそのまま使い、展開の規則をアプリが持たないため、`~` は展開しない。
  /// `fileKind` は symlink の参照先で判定する。`FileManager.isExecutableFile(atPath:)` だけでは
  /// ディレクトリも通るため、`fileExists(atPath:isDirectory:)` と組み合わせる必要がある。
  public static func resolve(
    overridePath: String?,
    candidates: [URL] = TmuxRunner.defaultExecutableCandidates,
    fileKind: (String) -> TmuxExecutableFileKind
  ) -> Self {
    if let path = overridePath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
      guard path.hasPrefix("/") else {
        return .overrideNotUsable(path: path, reason: .notAbsolute)
      }
      switch fileKind(path) {
      case .executableFile:
        return .found(URL(fileURLWithPath: path, isDirectory: false), source: .override)
      case .directory:
        return .overrideNotUsable(path: path, reason: .isDirectory)
      case .unusable:
        return .overrideNotUsable(path: path, reason: .notExecutable)
      }
    }

    for candidate in candidates where fileKind(candidate.path) == .executableFile {
      return .found(
        URL(fileURLWithPath: candidate.path, isDirectory: false), source: .defaultCandidate)
    }
    return .notFound(searched: candidates)
  }
}

import TerminalCore

public enum TmuxWindowSizeResumeRepair: Sendable, Equatable {
  /// 設計書 §3.3 に従い、生成時に設定し損ねた window だけを修復したことを呼び出し元へ残す。
  case applied(TmuxWindowSize)
  /// 設計書 §3.3 に従いユーザーの設定を上書きしない。アプリが選択肢に持たない値も保持するため、
  /// `TmuxWindowSize` へ変換せず原文の値を返す。
  case keptExisting(String)
}

extension TmuxSessionOperations {
  /// 設計書 §3.3 に従い、未設定だけを修復してユーザーの値は上書きしない。
  /// 生成時も window 単位で設定するため、global の継承値では修復の要否を判断しない。
  /// `-q` は不正な option 名のエラーも抑え、未設定と区別できなくなるため付けない (tmux 3.8 実測)。
  public func ensureWindowSizeIfUnset(
    session: TmuxSessionName,
    windowSize: TmuxWindowSize = Self.defaultWindowSize
  ) async throws(TmuxSessionOperationError) -> TmuxWindowSizeResumeRepair {
    let target = "=\(session.rawValue):"
    let result = try await run(
      ["show-options", "-w", "-t", target, "window-size"],
      session: session,
      messageTarget: target
    )
    let stdout = result.stdout
    if stdout.isEmpty {
      _ = try await run(
        ["set-option", "-w", "-t", target, "window-size", windowSize.rawValue],
        session: session,
        messageTarget: target
      )
      return .applied(windowSize)
    }

    let prefix = "window-size "
    guard stdout.hasPrefix(prefix), stdout.hasSuffix("\n") else {
      throw .unexpectedShowOptionsOutput(stdout)
    }
    let value = stdout.dropFirst(prefix.count).dropLast()
    guard !value.isEmpty, !value.contains(where: { $0.isWhitespace }) else {
      throw .unexpectedShowOptionsOutput(stdout)
    }
    return .keptExisting(String(value))
  }
}

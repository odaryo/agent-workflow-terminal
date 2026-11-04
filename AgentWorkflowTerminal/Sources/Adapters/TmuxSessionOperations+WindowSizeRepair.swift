import TerminalCore

public enum TmuxWindowSizeResumeRepair: Sendable, Equatable {
  /// Resume 時点の current window で window 単位の設定が無かったため、値を設定した。
  /// アプリ外で作られた session や、ユーザーが `set-option -wu` で設定を外した window も対象になる。
  /// 設計書 §4.1 の 1 window 運用を前提とするため、複数 window の session でも判定は current window
  /// で決まり、他の window の未設定は修復しない。
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

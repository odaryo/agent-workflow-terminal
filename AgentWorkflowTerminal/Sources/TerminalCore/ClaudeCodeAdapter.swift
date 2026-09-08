import Foundation

/// Claude Code 2.1.259 の画面と出力活動の実測だけを使う
/// (Spikes/gate3/README.md §3、§6.1、§11)。title は状態信号として使わない。
public struct ClaudeCodeAdapter: AgentAdapter {
  // Gate 3 §3.4 の working p90 は 1.01 秒。2 秒へ緩めると permission を working に
  // 倒すため、実測表で危険側の誤判定が 0 の 1.0 秒を境界にする。
  private static let activeScreenThresholdSeconds: TimeInterval = 1.0

  public let id = AgentAdapterID(rawValue: "claude-code")
  public let processNames: Set<String> = ["claude"]
  // idle 区間の画面変化は 1 行に収まる。Gate 3 の再採点 (Spikes/gate3/README.md §13) を
  // 250ms 分解能で数えると、独立した画面変化は idle 10 件が全件 1 行、working は 180 件中
  // 99 件が 2 行以上で、2 が実測上の分離点。2.0 秒 polling の 97/98・422/441 は 8 位相の
  // 合算値で、独立事象数ではない。記録で測れているのは起動後 25 秒の idle 区間だけである。
  public let minimumChangedLinesForScreenActivity = 2
  public init() {}

  public func classify(signals: AgentSignals, liveness: AgentLiveness) -> AgentObservationResult {
    guard liveness != .absent else { return .absent }
    guard liveness == .alive else { return unknown(signals, reason: .livenessUnavailable) }
    guard let screen = signals.screenText else {
      return unknown(signals, reason: .screenUnavailable)
    }
    if screen.contains("Do you want to ") || screen.contains("Esc to cancel · Tab to amend") {
      return observation(.permission, signals)
    }
    if screen.contains("Enter to select ·") && screen.contains("Type something.") {
      return observation(.question, signals)
    }
    let inputBox = Self.inputBoxContent(screen: screen, styled: signals.styledScreenText)
    // プレースホルダ (文脈サジェスト) が出ている入力欄は、利用者が何も打っていないので
    // 空欄と同じに扱う。plain text では入力済みテキストと区別できず、dim 属性だけが手掛かりである
    // (Issue #217 の実測: 区切りはどちらも NBSP で、サジェストに固定接頭辞は無い)。
    let hasEmptyInputPrompt =
      screen.range(of: #"(?m)^❯[  ]*$"#, options: .regularExpression) != nil
      || inputBox == .placeholder
    let hasSubmittedPrompt =
      screen.range(of: #"(?m)^❯[  ]*\S"#, options: .regularExpression) != nil
    if let elapsed = signals.secondsSinceScreenChange,
      elapsed <= Self.activeScreenThresholdSeconds
    {
      return observation(.working, signals)
    }
    guard signals.secondsSinceScreenChange != nil else {
      return unknown(signals, reason: .signalMissing)
    }
    // 起動バナーはスクロールアウトするため、idle の検出率に上限がある (Gate 3 §10-4)。
    if hasEmptyInputPrompt && screen.contains("Claude Code v") && screen.contains("mode on")
      && !screen.contains("⏺")
    {
      return observation(.idle, signals)
    }
    if hasEmptyInputPrompt, hasSubmittedPrompt,
      screen.range(of: #"·\s*done\s+\d"#, options: .regularExpression) != nil
    {
      return observation(.completed, signals)
    }
    // 属性が取れていれば定まったかもしれない判定を、adapter の見立て不能へ丸めない (§12.4.4)。
    if inputBox == .attributesUnavailable {
      return unknown(signals, reason: .screenAttributesUnavailable)
    }
    return unknown(signals, reason: .adapterUndetermined)
  }

  /// 入力欄の行を dim で分類する。
  ///
  /// - Important: 入力欄の行は `❯` の直後が NBSP であることで会話履歴の
  ///   `❯ <送信済み>` 行 (区切りは半角スペース) と分けられる (2.1.259 / 2.1.263 で実測)。
  ///   見つからなければ `.absent` を返し、呼び出し側は従来の plain ルールだけで判定する。
  static func inputBoxContent(screen: String, styled: String?) -> InputBoxContent {
    let lines = screen.split(separator: "\n", omittingEmptySubsequences: false)
    guard let index = lines.lastIndex(where: { $0.hasPrefix("❯ ") }) else { return .absent }
    let content = lines[index].dropFirst().drop { $0 == " " || $0 == " " }
    guard !content.isEmpty else { return .empty }
    guard let styled else { return .attributesUnavailable }
    let parsed = StyledScreenText(capturedWithEscapeSequences: styled)
    guard parsed.containsAnyStyling, index < parsed.lines.count,
      parsed.lines[index].text == lines[index]
    else {
      return .attributesUnavailable
    }
    let line = parsed.lines[index]
    var offset = 0
    while offset < line.characters.count, Self.isPromptSeparator(line.characters[offset]) {
      offset += 1
    }
    for position in offset..<line.characters.count
    where line.characters[position] != " " && !line.isDim[position] {
      return .typed
    }
    return .placeholder
  }

  private static func isPromptSeparator(_ character: Character) -> Bool {
    character == "❯" || character == " " || character == " "
  }

  enum InputBoxContent {
    case empty
    /// 文脈サジェスト。利用者の入力ではない。
    case placeholder
    case typed
    /// 属性が無いため placeholder と typed を分けられない。
    case attributesUnavailable
    /// 入力欄の行自体が画面に無い (permission / question のダイアログなど)。
    case absent
  }

  private func observation(_ state: AgentState, _ signals: AgentSignals) -> AgentObservationResult {
    .observation(AgentStateObservation(state: state, adapterID: id, observedAt: signals.observedAt))
  }

  private func unknown(_ signals: AgentSignals, reason: UnknownReason) -> AgentObservationResult {
    .observation(
      AgentStateObservation(
        state: .unknown, adapterID: id, observedAt: signals.observedAt, unknownReason: reason
      ))
  }
}

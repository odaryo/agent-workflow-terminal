import Foundation

/// Claude Code 2.1.259 / 2.1.319 の画面と出力活動の実測だけを使う
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
    if let state = Self.promptState(screen) {
      return observation(state, signals)
    }
    let inputBox = Self.inputBoxContent(screen: screen, styled: signals.styledScreenText)
    // プレースホルダ (文脈サジェスト) が出ている入力欄は、利用者が何も打っていないので
    // 空欄と同じに扱う。plain text では入力済みテキストと区別できず、dim 属性だけが手掛かりである
    // (Issue #217 の実測: 区切りはどちらも NBSP で、サジェストに固定接頭辞は無い)。
    let hasEmptyInputPrompt = inputBox == .empty || inputBox == .placeholder
    if let recentlyActive = recentScreenActivity(signals) {
      return recentlyActive
    }
    guard signals.secondsSinceScreenChange != nil else {
      return unknown(signals, reason: .signalMissing)
    }
    let hasScrolledTranscript = Self.hasScrolledTranscript(screen)
    if let state = Self.currentTurnState(
      screen: screen, hasEmptyInputPrompt: hasEmptyInputPrompt,
      hasScrolledTranscript: hasScrolledTranscript)
    {
      return observation(state, signals)
    }
    if hasScrolledTranscript {
      return unknown(signals, reason: .adapterUndetermined)
    }
    // 属性が取れていれば定まったかもしれない判定を、adapter の見立て不能へ丸めない (§12.4.4)。
    if inputBox == .attributesUnavailable {
      return unknown(signals, reason: .screenAttributesUnavailable)
    }
    return unknown(signals, reason: .adapterUndetermined)
  }

  private static func promptState(_ screen: String) -> AgentState? {
    let lines = screen.split(separator: "\n", omittingEmptySubsequences: false)
    if screen.contains("Do you want to ") || screen.contains("Esc to cancel · Tab to amend")
      || hasTrustPrompt(screen),
      hasActivePrompt(
        in: lines,
        containing: [
          "Do you want to ", "Esc to cancel · Tab to amend", "Enter to confirm · Esc to cancel",
          "Yes, I trust this folder",
          "Claude Code'll be able to read, edit, and execute files here.",
        ])
    {
      return .permission
    }
    if screen.contains("Enter to select ·") && screen.contains("Type something."),
      hasActivePrompt(in: lines, containing: ["Enter to select ·", "Type something."])
    {
      return .question
    }
    if hasPlanApprovalPrompt(screen) {
      return .permission
    }
    return nil
  }

  // Issue #645、設計書 §12.6・§12.8: 応答本文にも確認画面の文言が引用されるため、文言だけでは判断待ちにしない。
  private static func hasActivePrompt(in lines: [Substring], containing texts: [String]) -> Bool {
    guard
      let index = lines.lastIndex(where: { line in
        texts.contains { line.contains($0) }
      })
    else { return false }
    return !hasInputPromptOrDone(lines.dropFirst(index + 1))
  }

  private static func hasInputPromptOrDone(_ lines: ArraySlice<Substring>) -> Bool {
    lines.contains {
      $0.range(of: #"·\s*done\s+\d"#, options: .regularExpression) != nil
        || $0.hasPrefix("❯\u{00A0}")
    }
  }

  // Issue #252、設計書 §12.8: 2.1.319 で採取した trust 画面は選択肢の移動でも変わるため、
  // 画面変化による Working より優先する。文中の部分一致を避け、採取した行に限定する。
  private static func hasTrustPrompt(_ screen: String) -> Bool {
    let lines = screen.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    return lines.contains("Enter to confirm · Esc to cancel")
      && (lines.contains("Yes, I trust this folder")
        || lines.contains("❯ Yes, I trust this folder")
        || lines.contains("Claude Code'll be able to read, edit, and execute files here."))
  }

  // Issue #632: 2.1.319 の plan 承認は選択肢の移動でも画面が変わるため、
  // 画面変化による Working より優先する。本文の同じ文言だけでは承認待ちとしない。
  private static func hasPlanApprovalPrompt(_ screen: String) -> Bool {
    let lines = screen.split(separator: "\n", omittingEmptySubsequences: false)
    let trimmedLines = lines.map { $0.trimmingCharacters(in: .whitespaces) }
    return lines.indices.contains { index in
      guard trimmedLines[index].range(of: #"^❯ \d+\. "#, options: .regularExpression) != nil else {
        return false
      }
      let precedingText = trimmedLines[max(0, index - 8)..<index]
        .filter { !$0.isEmpty }.joined(separator: " ")
      let followingLines = lines.dropFirst(index + 1)
      return
        (precedingText.contains("Would you like to proceed?")
        || precedingText.contains("Exit plan mode?"))
        && !hasInputPromptOrDone(followingLines)
    }
  }

  private static func currentTurnState(
    screen: String, hasEmptyInputPrompt: Bool, hasScrolledTranscript: Bool
  ) -> AgentState? {
    // Issue #627: 2.1.319 の spinner は列 0 の「記号 + 半角空白 + 語 + …」で、
    // Gate 3 の 2.1.259 記録にも同じ形がある。経過表示がまだ無いターン開始直後も含む。
    // 履歴の spinner や前ターンの done を拾わないよう、最後の送信済みプロンプトより下だけを使う。
    // 送信済みの区切りは U+0020、入力欄は NBSP (2.1.259 / 2.1.263 / 2.1.319 で実測)。
    let lines = screen.split(separator: "\n", omittingEmptySubsequences: false)
    let lastSubmittedPromptIndex = lines.lastIndex {
      $0.range(of: #"^❯ +\S"#, options: .regularExpression) != nil
    }
    let currentTurnLines = lines.dropFirst(lastSubmittedPromptIndex.map { $0 + 1 } ?? 0)
    if currentTurnLines.contains(where: {
      $0.range(of: #"^[·✢✳✶✻✽] [^\s·][^·\n]*…(?: \(.*)?$"#, options: .regularExpression) != nil
    }) {
      return .working
    }
    // Issue #632: 2.1.319 の retry 待ちもターンが続いており、Idle では入力を送れてしまう。
    if currentTurnLines.indices.contains(where: { index in
      currentTurnLines[index].range(
        of: #"· Retrying in [^·]+ · attempt(?: \d+/\d+)?$"#, options: .regularExpression
      ) != nil
        && !currentTurnLines.suffix(from: index + 1).contains(where: {
          $0.range(of: #"·\s*done\s+\d"#, options: .regularExpression) != nil
        })
    }) {
      return .working
    }
    guard !hasScrolledTranscript else { return nil }
    // Issue #632: 2.1.319 では retry が尽きても done が出るため、正常完了と区別する。
    if hasCompletedAPIError(in: currentTurnLines) {
      return .error
    }
    if hasEmptyInputPrompt,
      isIdleAfterTurnWithoutCompletionLine(
        screen: screen, submittedPrompt: lastSubmittedPromptIndex.map { lines[$0] },
        turnLines: currentTurnLines)
    {
      return .idle
    }
    // 起動バナーはスクロールアウトするため、idle の検出率に上限がある (Gate 3 §10-4)。
    if hasEmptyInputPrompt && screen.contains("Claude Code v") && screen.contains("mode on")
      && !screen.contains("⏺")
      && lastSubmittedPromptIndex.map({
        lines[$0].range(of: #"^❯ +/"#, options: .regularExpression) != nil
      }) ?? true
    {
      return .idle
    }
    // Issue #382: 送信済みプロンプトで始まるターンでは、前ターンの完了行はそのプロンプトより上にあるため、
    // プロンプトが画面外へ流れたなら前ターンの完了行も画面内には残らない。プロンプトの無いターン
    // (バックグラウンドのコマンドの完了で始まる) と `--continue` の再開直後はこの限りでない (レビューで実測)。
    if hasEmptyInputPrompt,
      currentTurnLines.contains(where: {
        $0.range(of: #"·\s*done\s+\d"#, options: .regularExpression) != nil
      })
    {
      return .completed
    }
    return nil
  }

  private static func hasCompletedAPIError(in lines: ArraySlice<Substring>) -> Bool {
    let lastResponseIndex = lines.lastIndex(where: { $0.hasPrefix("⏺ ") })
    let responseErrorIndex = lastResponseIndex.flatMap { index in
      [
        "⏺ API Error:", "⏺ Please run /login · API Error:",
        "⏺ There's an issue with the selected model (",
      ].contains(where: { lines[index].hasPrefix($0) }) ? index : nil
    }
    // Issue #725: 深いインデントの引用を除くため列 2 に固定する。区切りには NBSP も混ざる。
    let nestedErrorIndex = lines.lastIndex(where: {
      $0.range(
        of: #"^  ⎿[ \x{00A0}]+(Not logged in · |Request timed out \("#
          + #"|Credit balance too low · |Prompt is too long · )"#,
        options: .regularExpression) != nil
    })
    let errorIndex =
      responseErrorIndex
      ?? nestedErrorIndex.flatMap { index in
        lastResponseIndex.map { $0 > index } == true ? nil : index
      }
    guard let errorIndex else { return false }
    return lines.suffix(from: errorIndex + 1).contains(where: {
      $0.range(of: #"·\s*done\s+\d"#, options: .regularExpression) != nil
    })
  }

  // Issue #631: 完了行を出さないターンは Unknown のままだと Diff コメントを送れない。
  // `!` の実行中と応答のストリーム中は入力欄が空でも次の入力を待っていない (footer の印で分かる)。
  private static func isIdleAfterTurnWithoutCompletionLine(
    screen: String, submittedPrompt: Substring?, turnLines: ArraySlice<Substring>
  ) -> Bool {
    guard !screen.contains("esc to interrupt"),
      !turnLines.contains(where: { $0.hasPrefix("! ") })
    else { return false }
    // `⎿` の後は半角空白と NBSP の並び (2.1.319 の実測)。列を固定して引用された同じ文言を除く。
    if let interruptedIndex = turnLines.lastIndex(where: {
      $0.range(of: #"^  ⎿[ \x{00A0}]+Interrupted · "#, options: .regularExpression) != nil
    }) {
      return !turnLines.suffix(from: interruptedIndex + 1).contains(where: {
        $0.hasPrefix("⏺ ")
          || $0.range(of: #"·\s*done\s+\d"#, options: .regularExpression) != nil
      })
    }
    guard let submittedPrompt,
      submittedPrompt.range(of: #"^❯ +/\S"#, options: .regularExpression) != nil,
      let firstOutput = turnLines.first(where: {
        !$0.trimmingCharacters(in: .whitespaces).isEmpty
      }),
      firstOutput.trimmingCharacters(in: .whitespaces).hasPrefix("⎿"),
      !firstOutput.contains("Running in the background")
    else { return false }
    return !turnLines.contains(where: { $0.hasPrefix("⏺ ") })
  }

  // Issue #653: スクロール中は最後の送信済みプロンプトが前のターンのものに見えるため、
  // 完了行や空欄から現ターンを確定できない。本文中の同じ文言を拾わないよう入力欄付近に限る。
  // 2.1.319 では同じ版でも新着メッセージ・マウスイベント・キー割り当て・端末幅で印が変わるため、
  // 先頭の文言だけを使い、後続の操作案内は問わない。本文に重ねて描かれるので行頭には限定しない。
  private static func hasScrolledTranscript(_ screen: String) -> Bool {
    let lines = screen.split(separator: "\n", omittingEmptySubsequences: false)
    guard let promptIndex = lines.lastIndex(where: { $0.hasPrefix("❯") }),
      let separatorIndex = lines[..<promptIndex].lastIndex(where: {
        let trimmed = $0.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed.allSatisfy { $0 == "─" }
      })
    else { return false }
    return lines[max(0, separatorIndex - 3)..<separatorIndex].contains {
      $0.range(of: #"(Jump to bottom|\d+ new messages?)"#, options: .regularExpression) != nil
    }
  }

  private func recentScreenActivity(_ signals: AgentSignals) -> AgentObservationResult? {
    guard let elapsed = signals.secondsSinceScreenChange,
      elapsed <= Self.activeScreenThresholdSeconds
    else { return nil }
    // 基準を作った直後の採取は、画面が変わっていなくても経過が小さい。変化を観測する前の
    // 経過は「変化が無かった時間の下限」でしかなく、Working の根拠にしない。比較対象が
    // まだ無いのと同じ扱いにする (Issue #559、設計書 §12.3)。
    guard signals.hasObservedScreenChange else {
      return unknown(signals, reason: .signalMissing)
    }
    return observation(.working, signals)
  }

  // 入力済みの先頭行は NBSP により会話履歴の `❯ <送信済み>` 行と分けられる
  // (2.1.259 / 2.1.263 で実測)。`❯` + U+0020 だけの行 (tmux が行末の空白を削ると `❯` だけになる) も、
  // 旧版の正規表現と同じく空欄とする。
  static func inputBoxContent(screen: String, styled: String?) -> InputBoxContent {
    let lines = screen.split(separator: "\n", omittingEmptySubsequences: false)
    guard let index = lines.lastIndex(where: { $0.hasPrefix("❯") }) else { return .absent }
    let followingLines = lines.dropFirst(index + 1)
    // Issue #270: 2.1.319 の \ + Enter の継続行は ❯ の下・区切りの上に出るため、
    // 先頭行が空でも空欄とは限らない。継続行の dim は実測が無いため入力済みとして扱う。
    if let separatorIndex = followingLines.firstIndex(where: {
      let trimmed = $0.trimmingCharacters(in: .whitespaces)
      return !trimmed.isEmpty && trimmed.allSatisfy { $0 == "─" }
    }),
      followingLines[..<separatorIndex].contains(where: {
        !$0.trimmingCharacters(in: .whitespaces).isEmpty
      })
    {
      return .typed
    }
    // 区切りの見えない狭い画面や旧版では継続行と出力を区別できないため、先頭行だけで決める。
    let content = lines[index].dropFirst().drop { $0 == " " || $0 == " " }
    guard !content.isEmpty else { return .empty }
    guard lines[index].hasPrefix("❯ ") else { return .absent }
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
    /// 最後の `❯` の行の下・区切りの上に文字がある場合も含む。そこが入力欄でないとき
    /// (permission / question のダイアログ、送信済みプロンプトが最後の `❯` の行のとき) にも
    /// 返るので、「利用者が打った」とは限らない。Idle / Completed へ丸めない向きにだけ使う。
    case typed
    /// 属性が無いため placeholder と typed を分けられない。
    case attributesUnavailable
    /// `❯` の行が無い、または最後の `❯` の行が入力欄 (`❯` + NBSP) でなく区切りも無い。
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

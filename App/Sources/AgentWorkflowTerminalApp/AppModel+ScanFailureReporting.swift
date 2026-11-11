import Adapters

extension AppModel {
  /// 失敗の集合が変わったときだけバナーを差し替える。集合が同じ間は、ユーザーが閉じた
  /// バナーを 5 秒ごとに復活させない (`reportedScanFailures` を閉じても消さないのはこのため)。
  ///
  /// - Important: 保存の成否に触れない文言にする。この起動で Active/Inactive を保存できるとは
  ///   限らず (`canSave`)、`previous` に居ないパスは保持のしようも無いため、「保持しています」は
  ///   どちらの場合にも偽になる。ここで言えるのは「観測できなかった」ことと、それを消失として
  ///   扱っていないことだけである。
  func report(
    scanFailures failures: [GitWorktreeEntryFailure], listingFailure: GitWorktreeListingFailure?
  ) {
    let summaries = Set(failures.map(Self.summary(of:)))
    var failureSet = Set(summaries.map { "entry: \($0)" })
    // 原文を鍵にしない。stdout に各 worktree の HEAD が入り、commit のたびに閉じたバナーが戻る。
    if listingFailure != nil {
      failureSet.insert("listing")
    }
    guard !failureSet.isEmpty else {
      updateScanFailureWarning(nil, failures: failureSet)
      return
    }
    var warnings: [String] = []
    switch listingFailure {
    case nil:
      break
    case .command:
      warnings.append("worktree の一覧を途中までしか読めませんでした。一覧に出なかった worktree は消えたものとしては扱っていません。")
    case .omittedRecords:
      // git は exit 0 のまま record を欠くので「途中まで」ではない (#774)。
      warnings.append(
        "git が一部の worktree を一覧に出しませんでした (管理ディレクトリが壊れているか読めません)。"
          + "一覧に出なかった worktree は消えたものとしては扱っていません。")
    }
    if !summaries.isEmpty {
      warnings.append(
        "\(summaries.count) 件の worktree を今回のスキャンで観測できませんでした。"
          + "消えたものとしては扱っていません: "
          + summaries.sorted().joined(separator: ", "))
    }
    // WarningBar は lineLimit(1) なので、改行で区切ると 2 文目が画面に出ない。
    updateScanFailureWarning(warnings.joined(separator: " "), failures: failureSet)
  }

  private static func summary(of failure: GitWorktreeEntryFailure) -> String {
    "\(failure.worktreePath) (\(summary(of: failure.reason)))"
  }

  /// git の生の出力はバナーに載せない (1行に収まらない)。原文は `NSLog` 側に残る。
  private static func summary(of reason: GitWorktreeEntryFailure.Reason) -> String {
    switch reason {
    case .gitDirectory(.process(.timedOut)): "git が応答しません"
    case .gitDirectory(.commandFailed(let exitCode, _, _)): "git が失敗しました (exit \(exitCode))"
    case .gitDirectory: "git を実行できません"
    case .unexpectedGitDirectoryOutput, .invalidGitDirectoryPath, .invalidCommonDirectoryPath:
      "git の出力を解釈できません"
    case .administrativeDirectoryNotFound: "管理ディレクトリを特定できません"
    case .resolvedToAncestorRepository: "worktree の .git が見つからず、祖先の repository を指しています"
    case .sharedIdentity: "別の worktree と同じ git ディレクトリを指しています (コピーや symlink で置き換わった可能性があります)"
    }
  }
}

import TerminalCore

/// `GitBranchMergeJudge` の merge 判定を、branch 先端と既定 branch 先端の OID の組で再利用する
/// (Issue #366)。Close の安全確認 (`GitCloseSafetyInspector`) と Overview のマージ済みの印
/// (`GitBranchMergeProbe`、Issue #879) が同じ cache を読み書きする。
///
/// 未マージの branch では squash 走査が上限まで回り切り、git 2.50.1 の実測で上限 300 に張り付く
/// 走査は 1 回 4.9〜5.1 秒かかった (隔離した一時 repository、1 commit で 2 ファイルを変更)。
/// Close の確認を開き直すたびにこれを払わないための再利用である。
///
/// replace ref と grafts は同じ OID の見かけの履歴を変えるため、検査では両方を無視することが前提となる。
///
/// 上限を下げる案を採らないのは、§3.4 の squash merge 検出の窓を狭めることになり、その代わりに
/// 選ぶ値の根拠が無いためである。再利用は判定の意味を変えない —— commit は不変なので、
/// 同じ2つの OID と同じ上限に対する ancestor 判定・merge-base・走査範囲は毎回同じ答えになる。
///
/// - Important: 既定 branch が動けば (並列レーン運用では日に 20 回以上) 鍵が変わって当たらない。
///   初回の所要時間は縮まないので、呼び出し側は検査を UI スレッドの外で走らせ、取り消せるようにする。
/// - Important: `.unknown` は保存しない。検査の失敗や取り消しで出た答えであり、次に問えば
///   答えられるかもしれない。
public actor GitBranchMergeCache {
  struct Key: Hashable, Sendable {
    let tip: CommitObjectID
    let destination: CommitObjectID
    let squashScanCommitLimit: Int
  }

  /// 鍵は既定 branch が動くたびに増える (印の経路は、動くたびに未マージの worktree の数だけ足す)
  /// ので、古いものから捨てる。押し出されて失うのは再利用による時間の節約だけで、判定の答えは
  /// 変わらない。
  static let capacity = 256

  private var entries: [Key: BranchMergeStatus] = [:]
  private var insertionOrder: [Key] = []

  public init() {}

  func status(for key: Key) -> BranchMergeStatus? {
    entries[key]
  }

  func store(_ status: BranchMergeStatus, for key: Key) {
    switch status {
    case .merged, .unmerged: break
    case .unknown, .notApplicable: return
    }
    if entries.updateValue(status, forKey: key) == nil {
      insertionOrder.append(key)
    }
    while insertionOrder.count > Self.capacity {
      entries[insertionOrder.removeFirst()] = nil
    }
  }
}

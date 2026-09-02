public enum ProcessTermination: Sendable, Hashable, Codable {
  /// POSIX の終了状態へ正規化した 0...255。範囲外を保持せず、生成側で正規化または拒否する。
  case exited(status: Int32)
  /// `SIG` 接頭辞を除いた小文字の短縮名。名前が無ければ十進文字列とし、バックエンド固有表記の
  /// 正規化は `AgentAdapter` 実装側で行う。
  case signaled(String)
  /// プロセス終了と理由の回収には時間差があり、理由が未観測でも終了済みという情報を失わない。
  case unknown
}

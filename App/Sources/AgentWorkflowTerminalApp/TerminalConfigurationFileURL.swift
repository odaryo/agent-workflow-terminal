import Foundation
import TerminalCore

/// Why not body のたびに解決: libghostty の設定はプロセスに1つで、最初の初期化時に固定される。
/// 後から違う URL を渡すと `GhosttyTerminalView` の初期化が失敗し、画面には何も出ない端末が
/// 残る。設定ファイルの有無はアプリの実行中に変わり得るので、値を1回だけ求めて固定する
/// (設計書 §21.6)。
let terminalConfigurationFileURL = TerminalConfigurationFile.resolve(
  environment: ProcessInfo.processInfo.environment,
  fileExists: { FileManager.default.fileExists(atPath: $0) })

import Foundation

/// Terminal 表示面のセルサイズ (桁数 × 行数)。
public struct TerminalSize: Sendable, Hashable, Codable {
  public let columns: Int
  public let rows: Int

  public init(columns: Int, rows: Int) {
    self.columns = columns
    self.rows = rows
  }
}

/// IME の変換候補ウィンドウを出す位置 (表示面座標、point 単位)。
///
/// - Important: libghostty v1.3.1 の `ime_point` は width にだけ content scale が
///   適用されていない (Spikes/gate1/README.md 申し送り #9)。
///   この差を吸収する責務は `TerminalRenderer` 実装体側に置き、
///   上位レイヤには常にスケール適用済みの値を渡す。
public struct TerminalIMEPoint: Sendable, Hashable {
  public let x: Double
  public let y: Double

  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }
}

/// `TerminalRenderer` の起動パラメータ。
public struct TerminalRendererConfiguration: Sendable, Hashable {
  /// 表示面で起動するコマンド (例: `tmux new-session -A -s <name>`)。
  public let command: [String]
  /// 作業ディレクトリ。
  public let workingDirectory: String?
  /// renderer 固有の設定ファイル。
  ///
  /// - Note: libghostty では `scrollback-limit` がメモリ予算の主要パラメータであり、
  ///   設定ロード経路が必要になる (Spikes/gate1/README.md 申し送り #13)。
  public let configurationFileURL: URL?

  public init(
    command: [String],
    workingDirectory: String? = nil,
    configurationFileURL: URL? = nil
  ) {
    self.command = command
    self.workingDirectory = workingDirectory
    self.configurationFileURL = configurationFileURL
  }
}

/// Terminal 描画の抽象境界 (設計書 §21.5)。
///
/// アプリ全体を libghostty API へ直接依存させず、この protocol で renderer を隔離する。
///
/// ```text
/// TerminalRenderer
/// ├─ GhosttyRenderer            # macOS、確定 (Gate 1 通過)
/// └─ MobileRenderer             # iOS/iPadOS、未確定
/// ```
///
/// - Important: 実装体は必ず `@MainActor` に固定する。libghostty のコールバックは
///   C 関数ポインタで actor 隔離を表現できず、`NSView` / `NSApplication` は
///   `@MainActor` であるため、C コールバックの入口で必ず main へ移す必要がある
///   (Spikes/gate1/README.md §5.2 / 申し送り #3)。
/// - Important: split / tab / zoom は tmux 側の責務であり、renderer 側の
///   split アクションは握り潰す (設計書 §4.1、Spikes/gate1/README.md 申し送り #15)。
///
/// - Note: Phase 1 時点では宣言のみ。操作セットの確定は renderer 実装時に行う。
///   `detach` すると surface のプロセスが死ぬため (申し送り #6)、
///   surface のライフサイクルはこの protocol の形に影響する見込み。
@MainActor
public protocol TerminalRenderer: AnyObject {
  /// 表示面が生きているか。
  ///
  /// - Note: ディスプレイスリープ中は surface を生成できないことがあり、
  ///   生成失敗時のフォールバックが必要 (Spikes/gate1/README.md 申し送り #7)。
  var isRunning: Bool { get }

  /// 現在の表示サイズ。
  var size: TerminalSize { get }

  /// IME 変換候補の表示位置 (スケール適用済み)。
  var imePoint: TerminalIMEPoint? { get }

  /// 表示面を起動する。
  func start(configuration: TerminalRendererConfiguration) throws

  /// 表示サイズを変更する。
  func resize(to size: TerminalSize)

  /// 表示面を終了する。
  func shutdown()
}

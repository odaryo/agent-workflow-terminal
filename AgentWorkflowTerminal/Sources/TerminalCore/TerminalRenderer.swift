import Foundation

/// 単位はセルであり、point でも pixel でもない。
public struct TerminalSize: Sendable, Hashable, Codable {
  public let columns: Int
  public let rows: Int

  public init(columns: Int, rows: Int) {
    self.columns = columns
    self.rows = rows
  }
}

/// 座標系は表示面ローカル、単位は point。
///
/// - Important: libghostty v1.3.1 の `ime_point` は width にだけ content scale が
///   適用されていない (Spikes/gate1/README.md 申し送り #9)。
///   この差を吸収する責務は `TerminalRenderer` 実装体側に置き、
///   上位レイヤには常にスケール適用済みの値を渡す。上位で再スケールしない。
public struct TerminalIMEPoint: Sendable, Hashable {
  public let x: Double
  public let y: Double

  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }
}

public struct TerminalRendererConfiguration: Sendable, Hashable {
  /// shell を経由せず argv として渡す。パイプ・リダイレクト・引用は解釈されないため、
  /// コマンド行を1本の文字列で組み立てない (例: `["tmux", "new-session", "-A", "-s", name]`)。
  public let command: [String]
  public let workingDirectory: String?
  /// このフィールドが存在するのは、libghostty の `scrollback-limit` が
  /// メモリ予算の主要パラメータであり、設定ファイルのロード経路を
  /// renderer に持たせる必要があるため (Spikes/gate1/README.md 申し送り #13)。
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

/// libghostty API をアプリ全体へ広げないための隔離境界 (設計書 §21.5)。
/// libghostty の型をこの protocol のシグネチャへ漏らさない。
///
/// - Important: 実装体は必ず `@MainActor` に固定する。libghostty のコールバックは
///   C 関数ポインタで actor 隔離を表現できず、`NSView` / `NSApplication` は
///   `@MainActor` であるため、C コールバックの入口で必ず main へ移す必要がある
///   (Spikes/gate1/README.md §5.2 / 申し送り #3)。
/// - Important: split / tab / zoom を操作として持たないのは、それが tmux 側の責務だから。
///   renderer 側の split アクションは握り潰す
///   (設計書 §4.1、Spikes/gate1/README.md 申し送り #15)。
///
/// - Note: Phase 1 時点では宣言のみで、操作セットは確定していない。
///   `detach` すると surface のプロセスが死ぬため (申し送り #6)、
///   surface のライフサイクルはこの protocol の形に影響する見込み。
@MainActor
public protocol TerminalRenderer: AnyObject {
  /// - Note: ディスプレイスリープ中は surface を生成できないことがあり、
  ///   `start` 成功後でも `false` になり得る。生成失敗は異常系ではなく、
  ///   遅延生成・リトライで扱う (Spikes/gate1/README.md 申し送り #7)。
  var isRunning: Bool { get }

  var size: TerminalSize { get }

  /// 値はスケール適用済み (`TerminalIMEPoint` の Important 参照)。
  var imePoint: TerminalIMEPoint? { get }

  func start(configuration: TerminalRendererConfiguration) throws

  func resize(to size: TerminalSize)

  func shutdown()
}

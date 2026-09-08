import SwiftUI
import TerminalCore

/// 表示中のタブの端末へキーボードフォーカスを戻す要求。
///
/// タブの切り替えは `ZStack` の `opacity` / `allowsHitTesting` で行うが、
/// `allowsHitTesting(false)` は AppKit の first responder を降ろさないため、隠れた端末が
/// 打鍵を受け続ける (Issue #233 の実測)。SwiftUI 側からその都度 first responder を
/// 取り直させるための、最小の置き場。
@MainActor
final class TerminalKeyboardFocus: ObservableObject {
  /// 値そのものに意味は無く、変わったことだけが「取り直せ」を表す。
  @Published private(set) var request = 0

  func requestFocus() {
    request &+= 1
  }

  /// - Note: Drawer が全画面のときは端末が画面に出ていない。取り返すと見えない端末へ
  ///   打鍵が入るので、そのときだけ要求しない。
  func tabSelectionChanged(drawerLayout: ViewerDrawerLayout) {
    guard drawerLayout.presentation != .fullscreen else { return }
    requestFocus()
  }

  /// Drawer の遷移のうち、キーボードの行き先が消えるものだけを拾う。開く・ペインを足す・
  /// 分割方向を変えるといった遷移でも取り返すと、Drawer 内で入力中のフォーカスを奪う。
  func drawerLayoutChanged(from old: ViewerDrawerLayout, to new: ViewerDrawerLayout) {
    let closed = old.isOpen && !new.isOpen
    let terminalReappeared = old.presentation == .fullscreen && new.presentation != .fullscreen
    guard closed || terminalReappeared else { return }
    requestFocus()
  }
}

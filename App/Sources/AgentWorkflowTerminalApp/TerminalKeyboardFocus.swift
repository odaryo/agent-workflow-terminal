import GhosttyRenderer
import SwiftUI
import TerminalCore

/// キーボードの持ち主 — 端末か Drawer のテキスト入力か — を調停する唯一の場所。
///
/// タブの切り替えは `ZStack` の `opacity` / `allowsHitTesting` で行うが、
/// `allowsHitTesting(false)` は AppKit の first responder を降ろさないため、隠れた端末が
/// 打鍵を受け続ける (Issue #233 の実測)。SwiftUI 側からその都度 first responder を
/// 取り直させるための、最小の置き場。
///
/// 端末が取りに行くのは「そのタブが表示中」かつ「テキスト入力が誰も主張していない」の
/// 両方が成り立つときだけ。端末側の grab は取り直し要求と surface の (再) 生成の2箇所に
/// あるが、どちらも `focusRequest(isTabSelected:)` の結果だけを読む — 判定を2つ置くと、
/// 片方だけ直して残る抜け道 (#233 は要求側だけを直し、再生成側が Issue #278 として残った)
/// が繰り返される。#240 が送信可否を `DiffCommentSendGate` の1箇所に閉じたのと同じ形。
///
/// 他の案を採らなかった理由 (Issue #278):
/// - *テキスト入力側の `@FocusState` だけで表す*: surface 再生成時の grab は AppKit 側で走り
///   SwiftUI の `@FocusState` を見ないので止まらない
/// - *主張中に来た要求を捨てる*: Drawer を閉じる遷移は要求を出すが、閉じると同時に
///   エディタの主張も解ける。捨てるとどちらもフォーカスを持たず、打鍵がどこにも入らない
/// - *主張が解けたら無条件に端末へ戻す*: エディタから Drawer 内の別のコントロールへ移った
///   だけのときに、ユーザーが選んでいない端末へフォーカスを動かしてしまう
/// - *端末が常に勝つ (Issue #278 以前)*: コメント欄に打鍵が一文字も入らない
@MainActor
final class TerminalKeyboardFocus: ObservableObject {
  /// 値そのものに意味は無く、変わったことだけが「取り直せ」を表す。
  @Published private(set) var request = 0
  /// 主張している入力欄。真偽ではなく持ち主の集合で持つのは、解除が二重に来ても、
  /// 対応する主張の開始より後に来ても壊れないため。
  @Published private(set) var textInputClaims: Set<UUID> = []

  func requestFocus() {
    request &+= 1
  }

  /// 端末側の2つの grab が共有する唯一の述語。`nil` は「このタブは表示されていない」だけを
  /// 意味し、「今は取るな」は `isTerminalAllowed` が別に持つ。
  func focusRequest(isTabSelected: Bool) -> TerminalFocusRequest? {
    guard isTabSelected else { return nil }
    return TerminalFocusRequest(token: request, isTerminalAllowed: textInputClaims.isEmpty)
  }

  /// SwiftUI の `@FocusState` の真偽をそのまま写す。AppKit 側に第二の真実を作らない。
  func setTextInputClaim(_ claiming: Bool, owner: UUID) {
    if claiming {
      textInputClaims.insert(owner)
    } else {
      textInputClaims.remove(owner)
    }
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

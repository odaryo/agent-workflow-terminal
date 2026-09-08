// 実 HID のマウスクリックを送る。scripts/verify-app-ui.sh から使う。
//
// Why not System Events の `click at`: **SwiftUI の `onTapGesture` を発火させない**。
// 同じアプリの同じ状態で実測すると、System Events のクリックでは Diff の行が選択されず
// (`行を選んでください` のまま)、CGEvent のクリックでは選択される (`選択中: … new 2`)。
// 一方で SwiftUI の Button (ラジオ等) は System Events のクリックでも反応するため、
// 「ボタンは動くのに行は動かない」を製品の欠陥と誤読しやすい。Issue #230 はこの誤読で起票され、
// not a bug として閉じた。
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count == 3, let x = Double(args[1]), let y = Double(args[2]) else {
  FileHandle.standardError.write(Data("使い方: ui-click.swift <x> <y>\n".utf8))
  exit(2)
}

let point = CGPoint(x: x, y: y)
let source = CGEventSource(stateID: .hidSystemState)

// down/up の前にカーソルを運ぶ。移動なしで down を送ると、hover 状態を前提にした
// ヒットテストが直前の位置のまま解決されることがある。
CGEvent(
  mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left
)?.post(tap: .cghidEventTap)
usleep(120_000)

for type in [CGEventType.leftMouseDown, .leftMouseUp] {
  let event = CGEvent(
    mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
  // クリック回数を明示しないと double click 扱いになる連投がある。
  event?.setIntegerValueField(.mouseEventClickState, value: 1)
  event?.post(tap: .cghidEventTap)
  usleep(60_000)
}

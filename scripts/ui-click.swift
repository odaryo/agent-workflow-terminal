// 実 HID のマウスクリックを送る。scripts/verify-app-ui.sh から使う。
//
// Why not System Events の `click at`: **SwiftUI の `onTapGesture` を発火させない**。
// 同じアプリの同じ状態で実測すると、System Events のクリックでは Diff の行が選択されず
// (`行を選んでください` のまま)、CGEvent のクリックでは選択される (`選択中: … new 2`)。
// 一方で SwiftUI の Button (ラジオ等) は System Events のクリックでも反応するため、
// 「ボタンは動くのに行は動かない」を製品の欠陥と誤読しやすい。Issue #230 はこの誤読で起票され、
// not a bug として閉じた。
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

func fail(_ message: String, code: Int32 = 1) -> Never {
  FileHandle.standardError.write(Data("\(message)\n".utf8))
  exit(code)
}

func requireClickTarget(at point: CGPoint, pid: pid_t) {
  let warning = "アプリのウィンドウが画面上で最前面にない。別のウィンドウや Space が覆っている可能性があります"
  var element: AXUIElement?
  let result = AXUIElementCopyElementAtPosition(
    AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &element)
  guard result == .success, let element else {
    fail("クリック中止: (\(point.x), \(point.y)) のアプリ不明 (AX エラー: \(result.rawValue))。\(warning)")
  }
  var actualPID: pid_t = 0
  let pidResult = AXUIElementGetPid(element, &actualPID)
  guard pidResult == .success, actualPID > 0 else {
    fail("クリック中止: (\(point.x), \(point.y)) のアプリの PID 取得失敗 (\(pidResult.rawValue))。\(warning)")
  }
  guard actualPID == pid else {
    fail("クリック中止: (\(point.x), \(point.y)) のアプリは PID \(actualPID) (対象 PID \(pid))。\(warning)")
  }
}

MainActor.assumeIsolated {
  let args = CommandLine.arguments
  guard args.count == 3, let x = Double(args[1]), let y = Double(args[2]),
    Float(x).isFinite, Float(y).isFinite
  else {
    fail("使い方: ui-click.swift <x> <y>", code: 2)
  }
  let processName = "AgentWorkflowTerminalApp"
  let applications = NSWorkspace.shared.runningApplications.filter {
    $0.executableURL?.lastPathComponent == processName || $0.localizedName == processName
  }
  guard applications.count == 1, let application = applications.first else {
    fail("対象プロセスを一意に特定できません: \(processName) (\(applications.count) 件)")
  }

  let point = CGPoint(x: x, y: y)
  let source = CGEventSource(stateID: .hidSystemState)

  // AXFrontmost が true でも別アプリが画面を覆い、HID クリックがそちらへ届くことを実測した。
  // 前面フラグだけでは信用できず、hover 待機中にも宛先が変わり得るため down 直前にも調べる。
  requireClickTarget(at: point, pid: application.processIdentifier)
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
    if type == .leftMouseDown {
      requireClickTarget(at: point, pid: application.processIdentifier)
    }
    event?.post(tap: .cghidEventTap)
    usleep(60_000)
  }
}

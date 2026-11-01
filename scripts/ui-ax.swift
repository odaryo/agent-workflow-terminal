import AppKit
import ApplicationServices
import Foundation

func fail(_ message: String, code: Int32 = 1) -> Never {
  FileHandle.standardError.write(Data("\(message)\n".utf8))
  exit(code)
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
    return nil
  }
  return value
}

func stringAttribute(_ element: AXUIElement, _ name: String) -> String {
  guard let value = attribute(element, name) else { return "" }
  if let attributed = value as? NSAttributedString { return attributed.string }
  if let string = value as? String { return string }
  if let number = value as? NSNumber { return number.stringValue }
  return ""
}

func elements(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
  attribute(element, name) as? [AXUIElement] ?? []
}

func geometry(_ element: AXUIElement) -> String? {
  guard let position = attribute(element, "AXPosition"),
    let size = attribute(element, "AXSize"),
    CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
  else { return nil }
  // CF の型 ID を検証してから変換する。AXValue は条件付きキャストを使えない。
  let positionValue = unsafeDowncast(position, to: AXValue.self)
  let sizeValue = unsafeDowncast(size, to: AXValue.self)
  var point = CGPoint.zero
  var dimensions = CGSize.zero
  guard AXValueGetType(positionValue) == .cgPoint, AXValueGetType(sizeValue) == .cgSize,
    AXValueGetValue(positionValue, .cgPoint, &point),
    AXValueGetValue(sizeValue, .cgSize, &dimensions)
  else { return nil }
  return "\(point.x) \(point.y) \(dimensions.width) \(dimensions.height)"
}

MainActor.assumeIsolated {
  let usage = "使い方: swift ui-ax.swift <プロセス名> <list|find|press> [文字列] [--exact] [--role AXRole]"
  let args = Array(CommandLine.arguments.dropFirst())
  guard args.count >= 2 else { fail(usage, code: 2) }
  let processName = args[0]
  let command = args[1]
  guard ["list", "find", "press"].contains(command) else { fail(usage, code: 2) }
  var needle: String?
  var exact = false
  var roleFilter: String?
  var index = 2
  while index < args.count {
    switch args[index] {
    case "--exact": exact = true
    case "--role":
      index += 1
      guard index < args.count else { fail(usage, code: 2) }
      roleFilter = args[index]
    default:
      guard needle == nil else { fail(usage, code: 2) }
      needle = args[index]
    }
    index += 1
  }
  guard command == "list" || needle != nil else { fail(usage, code: 2) }
  guard AXIsProcessTrusted() else { fail("Accessibility の権限がありません") }
  let applications = NSWorkspace.shared.runningApplications.filter {
    $0.executableURL?.lastPathComponent == processName || $0.localizedName == processName
  }
  guard applications.count == 1, let application = applications.first else {
    fail("対象プロセスを一意に特定できません: \(processName) (\(applications.count) 件)")
  }
  let root = AXUIElementCreateApplication(application.processIdentifier)
  let windows = elements(root, "AXWindows")
  guard !windows.isEmpty else { fail("AXWindows を取得できません: \(processName)") }

  // osascript の description of は役割名を返すため、AX 属性を直接読む。
  // SwiftUI の accessibilityLabel が AXAttributedDescription にしか出ない場合もある (#407)。
  let textAttributes = ["AXTitle", "AXValue", "AXDescription", "AXAttributedDescription"]
  var visited: [AXUIElement] = []

  @MainActor
  func visit(_ element: AXUIElement) {
    guard !visited.contains(where: { CFEqual($0, element) }) else { return }
    visited.append(element)
    let role = stringAttribute(element, "AXRole")
    let texts = textAttributes.map { stringAttribute(element, $0) }
    if roleFilter == nil || roleFilter == role {
      if command == "list" {
        let fields = zip(textAttributes, texts).map { "\($0)=\($1.debugDescription)" }
        print(([role] + fields).joined(separator: " "))
      } else if let needle, texts.contains(where: { exact ? $0 == needle : $0.contains(needle) }) {
        if command == "press" {
          let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
          guard result == .success else {
            fail("AXPress に失敗しました: \(needle) (\(result.rawValue))")
          }
        } else {
          guard let bounds = geometry(element) else { fail("座標を取得できません: \(needle)") }
          print(bounds)
        }
        exit(0)
      }
    }
    for child in elements(element, "AXChildren") { visit(child) }
  }

  for window in windows { visit(window) }
  if command != "list" { fail("要素が見つかりません: \(needle ?? "")") }
}

import AppKit
import SwiftUI

// `.toolbar` 内では `.contextMenu` が開かない (#431 の計測。本体側では開く)。
@MainActor
struct ToolbarContextMenu: NSViewRepresentable {
  enum Item {
    case action(title: String, isEnabled: Bool, perform: @MainActor () -> Void)
    case separator
  }

  let items: [Item]

  func makeNSView(context: Context) -> MenuView {
    let view = MenuView(frame: .zero)
    view.items = items
    return view
  }

  func updateNSView(_ view: MenuView, context: Context) {
    view.items = items
  }

  @MainActor
  final class MenuView: NSView {
    var items: [Item] = []
    private var actionTargets: [ActionTarget] = []

    override func hitTest(_ point: NSPoint) -> NSView? {
      // 通常の左クリックと help の hover を SwiftUI の Button へ通す。
      guard let event = NSApp.currentEvent,
        event.type == .rightMouseDown || event.type == .rightMouseUp
          || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
      else { return nil }
      return super.hitTest(point)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
      let menu = NSMenu()
      menu.autoenablesItems = false
      actionTargets = []
      for item in items {
        switch item {
        case .separator:
          menu.addItem(.separator())
        case .action(let title, let isEnabled, let perform):
          let target = ActionTarget(perform: perform)
          let menuItem = NSMenuItem(
            title: title, action: #selector(ActionTarget.invoke), keyEquivalent: "")
          menuItem.target = target
          menuItem.isEnabled = isEnabled
          menu.addItem(menuItem)
          actionTargets.append(target)
        }
      }
      return menu
    }
  }

  @MainActor
  private final class ActionTarget: NSObject {
    let perform: @MainActor () -> Void

    init(perform: @escaping @MainActor () -> Void) {
      self.perform = perform
      super.init()
    }

    @objc func invoke() {
      perform()
    }
  }
}

import AppKit
import SwiftUI

// toolbar 内では `.contextMenu` も重ねた view の右クリックも届かない (#431)。
// lldb では hitTest は mouseEntered 時だけ、menu(for:) は一度も呼ばれなかった。
@MainActor
struct ToolbarContextMenu: NSViewRepresentable {
  enum Item {
    case action(title: String, isEnabled: Bool, perform: @MainActor @Sendable () -> Void)
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
    // 外すのは window から外れたとき (viewDidMoveToWindow) だけ。isolated deinit は CI の Swift 6.1
    // では実験的機能で使えない。外し損ねても、モニタは weak self なのでイベントをそのまま返す。
    private var eventMonitor: Any?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard window != nil else {
        removeEventMonitor()
        return
      }
      guard eventMonitor == nil else { return }
      eventMonitor = NSEvent.addLocalMonitorForEvents(
        matching: [.rightMouseDown, .leftMouseDown]
      ) { [weak self] event in
        // ローカルモニタは main thread で呼ばれる。条件外まで消費すると他のクリックを壊す。
        let handled = MainActor.assumeIsolated {
          self?.showContextMenu(for: event) ?? false
        }
        return handled ? nil : event
      }
    }

    private func removeEventMonitor() {
      guard let eventMonitor else { return }
      NSEvent.removeMonitor(eventMonitor)
      self.eventMonitor = nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
      nil
    }

    private func showContextMenu(for event: NSEvent) -> Bool {
      guard let window, event.window === window, window.isVisible,
        !isHiddenOrHasHiddenAncestor,
        event.type == .rightMouseDown
          || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)),
        bounds.contains(convert(event.locationInWindow, from: nil))
      else { return false }
      NSMenu.popUpContextMenu(makeMenu(), with: event, for: self)
      return true
    }

    private func makeMenu() -> NSMenu {
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
    let perform: @MainActor @Sendable () -> Void

    init(perform: @escaping @MainActor @Sendable () -> Void) {
      self.perform = perform
      super.init()
    }

    @objc func invoke() {
      perform()
    }
  }
}

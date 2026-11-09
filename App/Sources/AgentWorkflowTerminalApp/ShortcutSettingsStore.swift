import Foundation
import SwiftUI
import TerminalCore

@MainActor
final class ShortcutSettingsStore: ObservableObject {
  @Published private(set) var bindings: ShortcutBindings
  @Published private(set) var errors: [ShortcutAction: String] = [:]
  let droppedCount: Int
  var registerGlobalHotKey: ((KeyCombination) -> String?)?
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let decoded = ShortcutBindings.decoded(from: defaults.data(forKey: "shortcutBindings"))
    bindings = decoded.bindings
    droppedCount = decoded.droppedCount
  }

  func shortcut(for action: ShortcutAction) -> KeyboardShortcut? {
    ShortcutConversion.keyboardShortcut(bindings.combination(for: action))
  }

  func assign(
    _ combination: KeyCombination, to action: ShortcutAction
  )
    throws(ShortcutAssignmentError)
  {
    var candidate = bindings
    try candidate.assign(combination, to: action)
    commit(candidate, action: action)
  }

  func resetToDefault(_ action: ShortcutAction) throws(ShortcutAssignmentError) {
    var candidate = bindings
    try candidate.resetToDefault(action)
    commit(candidate, action: action)
  }

  func resetAll() {
    var candidate = bindings
    candidate.resetAll()
    commit(candidate, action: .bringAppToFront, clearingErrors: true)
  }

  func showError(_ message: String?, for action: ShortcutAction) {
    errors[action] = message
  }

  func showError(_ error: ShortcutAssignmentError, for action: ShortcutAction) {
    let message: String
    switch error {
    case .unsupportedKey: message = "このキーは割り当てられません"
    case .commandModifierRequired: message = "⌘ を含むキーにしてください"
    case .reserved: message = "このキーはシステムやアプリが使っています"
    case .conflict(let other): message = "『\(other.settingsName)』に割り当て済みです"
    }
    showError(message, for: action)
  }

  private func commit(
    _ candidate: ShortcutBindings, action: ShortcutAction, clearingErrors: Bool = false
  ) {
    let global = candidate.combination(for: .bringAppToFront)
    if global != bindings.combination(for: .bringAppToFront) {
      guard ShortcutConversion.carbon(global) != nil else {
        errors[.bringAppToFront] = "このキーはシステム全体のショートカットに使えません"
        return
      }
      if let error = registerGlobalHotKey?(global) {
        errors[.bringAppToFront] = error
        return
      }
    }
    if clearingErrors { errors.removeAll() } else { errors[action] = nil }
    bindings = candidate
    defaults.set(bindings.encoded(), forKey: "shortcutBindings")
  }
}

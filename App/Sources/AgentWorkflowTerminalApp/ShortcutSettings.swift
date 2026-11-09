import AppKit
import SwiftUI
import TerminalCore

@MainActor
struct ShortcutSettingsView: View {
  @ObservedObject var store: ShortcutSettingsStore
  @StateObject private var recorder = ShortcutRecorder()

  var body: some View {
    Form {
      if store.droppedCount > 0 {
        Text("保存された割り当てのうち \(store.droppedCount) 件を読めなかったので既定に戻しました")
          .foregroundStyle(.orange)
      }
      ForEach(ShortcutAction.allCases, id: \.self) { action in
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Text(action.settingsName)
            Spacer()
            if recorder.action == action {
              Text("キーを押してください").foregroundStyle(.secondary)
            } else {
              Text(ShortcutConversion.display(store.bindings.combination(for: action)))
                .monospaced()
            }
            Button("変更") { recorder.start(action, store: store) }
            if !store.bindings.isDefault(action) {
              Button("既定に戻す") {
                recorder.stop()
                do throws(ShortcutAssignmentError) {
                  try store.resetToDefault(action)
                } catch {
                  store.showError(error, for: action)
                }
              }
            }
          }
          if action == .bringAppToFront {
            Text("どのアプリからでも効くので、他のアプリの同じキーより優先されます")
              .font(.caption).foregroundStyle(.secondary)
          }
          if let error = store.errors[action] {
            Text(error).font(.caption).foregroundStyle(.red)
          }
        }
      }
      Text("⌃Tab / ⌃⇧Tab は固定のため変更できません。Esc でキーの記録を取り消します。")
        .font(.caption).foregroundStyle(.secondary)
      Button("すべて既定に戻す") {
        recorder.stop()
        store.resetAll()
      }
    }
    .formStyle(.grouped)
    .frame(width: 650, height: 600)
    .onDisappear { recorder.stop() }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
      recorder.stop()
    }
  }
}

@MainActor
private final class ShortcutRecorder: ObservableObject {
  @Published private(set) var action: ShortcutAction?
  private var monitor: Any?

  func start(_ action: ShortcutAction, store: ShortcutSettingsStore) {
    stop()
    self.action = action
    store.showError(nil, for: action)
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      let keyCode = event.keyCode
      let characters = event.characters(byApplyingModifiers: [])
      let modifiers = event.modifierFlags
      // AppKit の local monitor はメインスレッド上で同期的にイベントを処理する。
      // NSEvent は Sendable でないので、actor をまたぐ前に値へ取り出す。
      let isConsumed = MainActor.assumeIsolated {
        guard let self else { return false }
        self.receive(
          keyCode: keyCode, characters: characters, modifiers: modifiers, action: action,
          store: store)
        return true
      }
      return isConsumed ? nil : event
    }
  }

  private func receive(
    keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags,
    action: ShortcutAction, store: ShortcutSettingsStore
  ) {
    stop()
    guard keyCode != 53 else { return }
    guard
      let combination = ShortcutConversion.recorded(
        keyCode: keyCode, characters: characters, modifiers: modifiers)
    else {
      store.showError(.unsupportedKey, for: action)
      return
    }
    do { try store.assign(combination, to: action) } catch { store.showError(error, for: action) }
  }

  func stop() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    action = nil
  }
}

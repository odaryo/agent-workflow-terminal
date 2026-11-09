import Carbon
import Foundation

@MainActor
final class GlobalHotKey {
  private let action: @MainActor () -> Void
  private var hotKey: EventHotKeyRef?
  private var eventHandler: EventHandlerRef?

  init(action: @escaping @MainActor () -> Void) {
    self.action = action
  }

  func register(keyCode: UInt32, modifiers: UInt32) -> OSStatus {
    if let hotKey {
      let status = UnregisterEventHotKey(hotKey)
      guard status == noErr else { return status }
      self.hotKey = nil
    }

    if eventHandler == nil {
      var eventType = EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
      let status = InstallEventHandler(
        GetApplicationEventTarget(), Self.callback, 1, &eventType,
        Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
      guard status == noErr else { return status }
    }

    return RegisterEventHotKey(
      keyCode, modifiers, EventHotKeyID(signature: 0x4157_5448, id: 1),
      GetApplicationEventTarget(), 0, &hotKey)
  }

  // Carbon は actor 隔離を表現できないので、UI に触れる前にメインキューへ渡す。
  // userData は非保持参照のため、このインスタンスはアプリの寿命と同じだけ保持する。
  nonisolated private static let callback:
    @convention(c) (EventHandlerCallRef?, EventRef?, UnsafeMutableRawPointer?) -> OSStatus =
      { _, _, userData in
        guard let userData else { return OSStatus(eventNotHandledErr) }
        let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            hotKey.action()
          }
        }
        return noErr
      }
}

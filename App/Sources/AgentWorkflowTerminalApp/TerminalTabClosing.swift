import Adapters
import SwiftUI
import TerminalCore

@MainActor
final class TerminalTabClosing: ObservableObject {
  struct Confirmation {
    let key: TerminalSessionKey
    let title: String
    let activity: TerminalSessionActivity
  }

  @Published private(set) var confirmation: Confirmation?
  private var inspectingKey: TerminalSessionKey?
  private var inspection: Task<Void, Never>?
  private(set) var isTerminating = false

  func inspect(
    _ key: TerminalSessionKey, probe: TmuxSessionActivityProbe,
    completion: @escaping @MainActor (TerminalSessionActivity) -> Void
  ) {
    guard !isTerminating, inspectingKey != key else { return }
    cancel()
    inspectingKey = key
    inspection = Task {
      let activity = await probe.activity(of: key)
      guard !Task.isCancelled else { return }
      inspectingKey = nil
      inspection = nil
      completion(activity)
    }
  }

  func showConfirmation(_ key: TerminalSessionKey, title: String, activity: TerminalSessionActivity)
  {
    confirmation = Confirmation(key: key, title: title, activity: activity)
  }

  func cancel() {
    inspection?.cancel()
    inspection = nil
    inspectingKey = nil
    confirmation = nil
  }

  func beginTermination() {
    cancel()
    isTerminating = true
  }

  func finishTermination() {
    isTerminating = false
  }
}

import AppKit
import SwiftUI
import TerminalCore

func overviewMenuLines(_ text: String, maxWidth: Int = 60) -> [String] {
  let characters = Array(text)
  var lines: [String] = []
  var start = 0
  while start < characters.count {
    if characters[start] == " " {
      start += 1
      continue
    }
    var end = start
    var width = 0
    var lastSpace: Int?
    while end < characters.count {
      let nextWidth = overviewMenuCharacterWidth(characters[end])
      if end > start && width + nextWidth > maxWidth { break }
      width += nextWidth
      if characters[end] == " " { lastSpace = end }
      end += 1
    }
    let split = end < characters.count ? lastSpace ?? end : end
    var trimmedEnd = split
    while trimmedEnd > start && characters[trimmedEnd - 1] == " " {
      trimmedEnd -= 1
    }
    lines.append(String(characters[start..<trimmedEnd]))
    start = split
  }
  return lines
}

private func overviewMenuCharacterWidth(_ character: Character) -> Int {
  guard let scalar = character.unicodeScalars.first else { return 1 }
  if scalar.properties.isEmojiPresentation { return 2 }
  switch scalar.value {
  case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF,
    0x4E00...0x9FFF, 0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
    0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x20000...0x3FFFD:
    return 2
  default:
    return 1
  }
}

struct OverviewPaneSummaryItems: View {
  let purpose: String
  let title: String?
  let status: String?

  var body: some View {
    let purposeValue = purpose.isEmpty ? title.flatMap { $0.isEmpty ? nil : $0 } : purpose
    let statusValue = status.flatMap { $0.isEmpty ? nil : $0 }
    if purposeValue != nil || statusValue != nil {
      if let purposeValue {
        OverviewMenuTextItems(
          heading: purpose.isEmpty ? "目的 (pane の title)" : "目的", text: purposeValue)
      }
      if let statusValue {
        OverviewMenuTextItems(heading: "現在地", text: statusValue)
      }
      if let purposeValue {
        Button("目的をコピー") { copy(purposeValue) }
      }
      if let statusValue {
        Button("現在地をコピー") { copy(statusValue) }
      }
      Divider()
    }
  }

  private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}

private struct OverviewMenuTextItems: View {
  let heading: String
  let text: String

  var body: some View {
    Button(heading) {}.disabled(true)
    let lines = overviewMenuLines(text)
    ForEach(lines.indices, id: \.self) { index in
      Button(lines[index]) {}.disabled(true)
    }
  }
}

struct OverviewPaneIDItems: View {
  let panes: [OverviewPane]

  var body: some View {
    ForEach(panes, id: \.paneID) { pane in
      Button(
        paneIDMenuTitle(paneID: pane.paneID, isMain: pane.isMain, location: pane.detail.location)
      ) {}
      .disabled(true)
    }
  }
}

struct OverviewSessionMenu: View {
  @ObservedObject var model: AppModel
  let key: TerminalSessionKey
  let selectProject: () -> Void

  var body: some View {
    Button("新規セッション") {
      selectProject()
      Task {
        await model.openNewSession(in: key.identity)
        model.paneObservations.requestTerminalFocus()
      }
    }
    .disabled(!model.canOpenSession(in: key.identity))
    Button("セッションを閉じる") {
      selectProject()
      model.requestCloseSession(key)
    }
    .disabled(!model.canCloseSession(key))
  }
}

struct OverviewProjectMenu: View {
  @ObservedObject var model: AppModel
  let selectProject: () -> Void
  let onSetAgentCommand: (RegisteredProject) -> Void
  let requestUnregister: (WorktreeIdentity) async -> Void

  var body: some View {
    Button("新規セッション (Project Root)") {
      selectProject()
      guard let projectRoot = model.projectRoot else { return }
      Task {
        await model.openNewSession(in: projectRoot.identity)
        model.paneObservations.requestTerminalFocus()
      }
    }
    .disabled(model.projectRoot.map { !model.canOpenSession(in: $0.identity) } ?? true)
    Menu("Inactive の worktree を Active にする") {
      ForEach(model.inactiveWorktrees, id: \.identity) { worktree in
        Button(title(of: worktree)) {
          model.setActivation(.active, of: worktree.identity)
        }
        .disabled(!worktree.detected.isReachable)
      }
    }
    .disabled(model.inactiveWorktrees.isEmpty)
    Button("Agent 起動コマンド…") {
      selectProject()
      onSetAgentCommand(model.project)
    }
    Button("登録を解除…") {
      selectProject()
      Task { await requestUnregister(model.project.commonDirectory) }
    }
  }

  private func title(of worktree: TaskWorktree) -> String {
    let name = worktree.detected.directoryName
    switch worktree.detected.observation {
    case .reachable: return name
    case .unreachable: return "\(name) (到達不能)"
    case .observationFailed: return "\(name) (観測失敗)"
    }
  }
}

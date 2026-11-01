import AppKit
import SwiftUI
import TerminalCore

struct TabSummaryMenu: View {
  @ObservedObject var model: AppModel
  // AppModel は子の変更を転送しないため、観測結果とメイン pane の登録も直接購読する。
  @ObservedObject private var store: PaneObservationStore
  @ObservedObject private var mainPanes: MainPaneCoordinator
  let items: [ToolbarContextMenu.Item]

  init(model: AppModel, items: [ToolbarContextMenu.Item]) {
    self.model = model
    store = model.paneObservations
    mainPanes = model.mainPanes
    self.items = items
  }

  var body: some View {
    ToolbarContextMenu(items: items + summaryItems)
  }

  private var summaryItems: [ToolbarContextMenu.Item] {
    let inputs = model.tabKeys.compactMap { model.worktreeInput($0) }
    let summaries = Dictionary(
      uniqueKeysWithValues: makeTabSummaries(inputs).map { ($0.session, $0) })
    return [.separator, .heading(title: "全タブ")]
      + model.tabKeys.flatMap { key -> [ToolbarContextMenu.Item] in
        let summary = summaries[key]
        let presentation: AgentStatePresentation? = summary == nil ? .unobserved("観測なし") : nil
        let heading = entry(
          title: model.sessionTitle(key), presentation: presentation, key: key,
          indentationLevel: 0, isChecked: model.selectedTab == key)
        return [heading] + (summary?.rows.map { rowItem($0, key: key) } ?? [])
      }
  }

  private func rowItem(_ row: OverviewRow, key: TerminalSessionKey) -> ToolbarContextMenu.Item {
    switch row {
    case .pane(let pane):
      var title = paneShortName(
        paneID: pane.paneID, isMain: pane.isMain, location: pane.detail.location)
      if let purpose = pane.detail.purpose, !purpose.isEmpty { title += "  \(purpose)" }
      if pane.detail.isTaskCompleted { title += " ✓完了" }
      return entry(
        title: title,
        presentation: AgentStatePresentation(
          state: pane.display.state, category: pane.display.category),
        key: key, indentationLevel: 1)
    case .noAgentPane:
      return entry(title: "Agent pane なし", presentation: nil, key: key, indentationLevel: 1)
    }
  }

  private func entry(
    title: String, presentation: AgentStatePresentation?, key: TerminalSessionKey,
    indentationLevel: Int, isChecked: Bool = false
  ) -> ToolbarContextMenu.Item {
    .entry(
      ToolbarContextMenu.Entry(
        title: title,
        symbol: presentation.map { (name: $0.symbol, color: NSColor($0.color)) },
        accessibilityLabel: presentation.map { "\($0.label) \(title)" } ?? title,
        indentationLevel: indentationLevel, isChecked: isChecked,
        perform: {
          model.select(key)
          store.requestTerminalFocus()
        }))
  }
}

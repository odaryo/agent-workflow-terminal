import Adapters
import SwiftUI
import TerminalCore

/// Viewer Drawer の `.code` ペイン (設計書 §7.1〜§7.3)。
/// 表示するパスは列挙で得た木からしか作らない。ユーザー入力や外の世界から来たパスを
/// `FileContentReader` へ渡すと、§8.1 が確定させた「常に現在の worktree 内だけ」を破れる
/// (`FileContentReader` は worktree root を知らない)。
struct CodeViewerPane: View {
  @StateObject private var model: FileBrowserModel
  @Environment(\.colorScheme) private var colorScheme

  init(worktreeRoot: URL) {
    _model = StateObject(wrappedValue: FileBrowserModel(worktreeRoot: worktreeRoot))
  }

  var body: some View {
    HSplitView {
      FileBrowserList(model: model)
        .frame(minWidth: 180, idealWidth: 240)
      CodeViewerContent(model: model)
        .frame(minWidth: 240, maxWidth: .infinity)
    }
    .task {
      model.prefersDarkTheme = colorScheme == .dark
      // タブの活性化 = このペインが階層に現れた時。ここで列挙と Git 状態を取り直す。
      model.loadRoot()
    }
    .task(id: model.selection) {
      model.resetSelectionState()
      await model.loadContent()
      await watchSelectedFile()
    }
    .onChange(of: colorScheme) { _, scheme in
      model.prefersDarkTheme = scheme == .dark
      Task { await model.loadContent() }
    }
    .task {
      await watchGitIndex()
    }
  }

  /// Drawer を閉じるとこのビューが階層から外れ、`task` ごと監視が止まる。
  private func watchSelectedFile() async {
    guard let selection = model.selection else { return }
    let watcher = FileChangeWatcher(path: selection.url)
    for await event in watcher.events() {
      switch event {
      case .modified:
        await model.loadContent()
      case .deleted:
        model.markSelectionDeleted()
      }
    }
  }

  /// commit / stash / checkout は `.git/index` の mtime を動かすので、badge の更新契機になる。
  private func watchGitIndex() async {
    guard let indexURL = model.gitIndexURL else { return }
    for await _ in FileChangeWatcher(path: indexURL).events() {
      model.refreshGitState()
    }
  }
}

private struct FileBrowserList: View {
  @ObservedObject var model: FileBrowserModel

  var body: some View {
    VStack(spacing: 0) {
      if let banner = gitStateBanner {
        Label(banner, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
        Divider()
      }
      List(model.rows) { row in
        FileBrowserRowView(model: model, row: row)
          .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
      }
      .listStyle(.sidebar)
      Divider()
      HStack {
        Button("Git 状態を更新", systemImage: "arrow.clockwise") { model.refreshGitState() }
          .buttonStyle(.borderless)
          .font(.caption)
        Spacer()
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
    }
  }

  private var gitStateBanner: String? {
    if let error = model.gitStateError {
      return "Git 状態を取得できません: \(error)"
    }
    guard let state = model.gitState else { return nil }
    var messages: [String] = []
    if state.incompleteEntryCount > 0 {
      messages.append("Git 状態の一部を取得できていません (\(state.incompleteEntryCount) 件)")
    }
    if state.submoduleListingFailed {
      messages.append("サブモジュールの所在が不明です (配下が誤って tracked に見えることがあります)")
    }
    return messages.isEmpty ? nil : messages.joined(separator: " / ")
  }
}

private struct FileBrowserRowView: View {
  @ObservedObject var model: FileBrowserModel
  let row: FileBrowserRow

  var body: some View {
    switch row.content {
    case .note(let message):
      Text(message)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.leading, indent)
    case .entry(let kind, let path, _):
      HStack(spacing: 4) {
        disclosure(kind: kind, isResolvable: path != nil)
        Image(systemName: kind == .directory ? "folder" : "doc")
          .foregroundStyle(.secondary)
        // 表示名はファイルシステムから得たものをそのまま出す。`WorktreeRelativePath` は
        // NFC 正規化済みなので、表示に使うとディスク上の名前と食い違う。
        Text(row.name)
          .foregroundStyle(nameColor)
          .lineLimit(1)
          .truncationMode(.middle)
          .layoutPriority(1)
        if let badge {
          Text(badge.text)
            .font(.caption2.monospaced())
            .foregroundStyle(badge.color)
            .fixedSize()
        }
        if path == nil {
          // 合成した相対パスを `WorktreeRelativePath` にできない = 状態を引くキーが無い。
          // 黙って捨てると既定規則で「変更なし」に化ける (§12.3)。
          Text("パス不明")
            .font(.caption2)
            .foregroundStyle(.orange)
        }
        Spacer(minLength: 0)
      }
      .padding(.leading, indent)
      .contentShape(.rect)
      .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
      .onTapGesture {
        if kind == .directory {
          model.toggleExpansion(of: row)
        } else {
          model.select(row)
        }
      }
    }
  }

  @ViewBuilder
  private func disclosure(kind: FileBrowserChildKind, isResolvable: Bool) -> some View {
    if kind == .directory, isResolvable {
      Image(systemName: model.isExpanded(row) ? "chevron.down" : "chevron.right")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(width: 10)
    } else {
      Color.clear.frame(width: 10, height: 1)
    }
  }

  private var indent: CGFloat { CGFloat(row.depth) * 12 }

  private var isSelected: Bool { model.selection?.id == row.id }

  private var state: WorktreeFileGitState? { model.gitState(for: row) }

  private var nameColor: Color {
    // §7.1: untracked / ignored はグレーで区別する。状態なし (`nil`) は「変更なし」ではないが、
    // badge を出さない点では同じ見た目でよい。型としては潰さない。
    switch state {
    case .untracked, .ignored: .secondary
    case .tracked, nil: .primary
    }
  }

  private var badge: (text: String, color: Color)? {
    switch state {
    case nil:
      nil
    case .untracked:
      ("?", .orange)
    case .ignored:
      ("!", .secondary)
    case .tracked(let status):
      status.displayedStatus == .unchanged ? nil : (status.badgeText, status.badgeColor)
    }
  }
}

extension WorktreeTrackedFileStatus {
  fileprivate var badgeText: String {
    switch displayedStatus {
    case .unchanged: ""
    case .modified: "M"
    case .typeChanged: "T"
    case .added: "A"
    case .deleted: "D"
    case .renamed: "R"
    case .copied: "C"
    case .unmerged: "U"
    }
  }

  fileprivate var badgeColor: Color {
    displayedStatus == .unmerged ? .red : .blue
  }
}

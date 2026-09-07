import Adapters
import SwiftUI
import TerminalCore

/// Viewer Drawer の `.diff` ペイン (設計書 §9)。行選択・コメント入力・送信は持たない (Issue #208)。
struct DiffViewerPane: View {
  @ObservedObject var model: DiffViewerModel

  var body: some View {
    VStack(spacing: 0) {
      controls
      Divider()
      banners
      // HSplitView は VStack の中では余った縦を自分から取りに行かない (実測: 上下に空きが出る)。
      // 明示的に優先度を上げて、残りの高さをこのペインへ渡す。
      content
        .layoutPriority(1)
    }
    .task { await model.loadContextIfNeeded() }
    .task {
      // Drawer を閉じるとこのビューが階層から外れ、`task` ごと監視が止まる。
      while !Task.isCancelled {
        try? await Task.sleep(for: DiffViewerModel.changeCheckInterval)
        guard !Task.isCancelled else { return }
        await model.checkForChanges()
      }
    }
  }

  // MARK: - 操作

  @ViewBuilder
  private var controls: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Picker("種別", selection: $model.kind) {
          Text("Commit").tag(DiffViewerModel.Kind.commit)
          Text("Base").tag(DiffViewerModel.Kind.base)
          Text("Branch").tag(DiffViewerModel.Kind.branch)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        Button(model.currentSnapshot == nil ? "開く" : "Refresh", systemImage: "arrow.clockwise") {
          Task { await model.openSnapshot() }
        }
        .disabled(model.isLoading)
      }
      subjectSelector
      if let snapshot = model.currentSnapshot {
        HStack {
          Picker("レビュー状態", selection: reviewStateBinding(snapshot)) {
            Text("Reviewing").tag(DiffReviewState.reviewing)
            Text("Reviewed").tag(DiffReviewState.reviewed)
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .frame(maxWidth: 200)
          if model.history.count > 1 {
            snapshotHistoryMenu
          }
          Spacer()
        }
      }
    }
    .padding(8)
  }

  private func reviewStateBinding(_ snapshot: DiffSnapshot) -> Binding<DiffReviewState> {
    Binding(get: { snapshot.reviewState }, set: { model.setReviewState($0) })
  }

  @ViewBuilder
  private var subjectSelector: some View {
    switch model.kind {
    case .base:
      HStack {
        Text("base: \(model.baseBranchDescription)")
          .font(.caption)
        branchMenu(title: "選び直す") { model.selectBaseBranch($0) }
        Spacer()
      }
    case .branch:
      HStack {
        Text("比較先: \(model.selectedBranch ?? "未選択")")
          .font(.caption)
        branchMenu(title: "選ぶ") { model.selectBranch($0) }
        Spacer()
      }
    case .commit:
      HStack {
        Text(model.selectedCommit.map { "\($0.abbreviatedHash) \($0.subject)" } ?? "未選択")
          .font(.caption)
          .lineLimit(1)
        Menu("選ぶ") {
          ForEach(model.commits, id: \.hash) { commit in
            Button("\(commit.abbreviatedHash) \(commit.subject)") { model.selectCommit(commit) }
          }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        Spacer()
      }
    }
  }

  private func branchMenu(title: String, action: @escaping (String) -> Void) -> some View {
    Menu(title) {
      ForEach(model.refNames?.all ?? [], id: \.self) { name in
        Button(name) { action(name) }
      }
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
  }

  private var snapshotHistoryMenu: some View {
    Menu("履歴 (\(model.history.count))") {
      ForEach(model.history.snapshots.reversed(), id: \.id) { snapshot in
        Button(Self.snapshotLabel(snapshot)) { model.showSnapshot(snapshot.id) }
      }
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
  }

  private static func snapshotLabel(_ snapshot: DiffSnapshot) -> String {
    let time = snapshot.createdAt.formatted(date: .omitted, time: .standard)
    let state = snapshot.reviewState == .reviewed ? "Reviewed" : "Reviewing"
    return "\(time) — \(state)"
  }

  // MARK: - 通知

  @ViewBuilder
  private var banners: some View {
    VStack(alignment: .leading, spacing: 2) {
      if case .undetermined = model.baseBranch, model.kind == .base {
        banner("base branch を判定できません。選び直してください。", icon: "questionmark.circle")
      }
      if let error = model.errorMessage {
        banner(error, icon: "exclamationmark.triangle")
      }
      if model.isViewingOldSnapshot {
        banner("過去の snapshot を表示しています。", icon: "clock.arrow.circlepath")
      }
      if let comparison = model.changeSinceOpened, comparison.hasChanges {
        banner(Self.changeMessage(comparison), icon: "exclamationmark.arrow.circlepath")
      }
      if model.changeSinceOpened?.head == .unknown {
        banner("HEAD を観測できず、変更の有無を判断できません。", icon: "questionmark.circle")
      }
      ForEach(model.notices, id: \.self) { notice in
        banner(notice, icon: "exclamationmark.triangle")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private static func changeMessage(_ comparison: DiffSnapshotComparison) -> String {
    let paths = comparison.changedPaths
    let head = comparison.head == .changed ? " (HEAD も動いています)" : ""
    guard !paths.isEmpty else { return "この Diff を開いてから HEAD が動いています。" }
    return "この Diff を開いてから \(paths.count) 件のファイルが変更されています\(head)"
  }

  private func banner(_ message: String, icon: String) -> some View {
    Label(message, systemImage: icon)
      .font(.caption)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
  }

  // MARK: - 本体

  @ViewBuilder
  private var content: some View {
    if let snapshot = model.currentSnapshot {
      // Why not HSplitView: VStack の中に置くと縦に伸びず、ペイン下部に空きが出る (実測)。
      // 幅の調整より、Drawer いっぱいに差分が出ることを優先する。
      HStack(spacing: 0) {
        DiffFileList(model: model, snapshot: snapshot)
          .frame(width: 240)
        Divider()
        DiffHunkView(file: selectedFile(in: snapshot), selection: model.selection)
          .frame(minWidth: 200, maxWidth: .infinity)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if model.isLoading {
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ContentUnavailableView(
        "Diff", systemImage: "arrow.left.arrow.right",
        description: Text("種別と比較先を選んで「開く」を押すと、その時点で固定した Diff を表示します。")
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func selectedFile(in snapshot: DiffSnapshot) -> UnifiedDiffFile? {
    guard let selection = model.selection else { return nil }
    return snapshot.file(origin: selection.origin, path: selection.path)
  }
}

private struct DiffFileList: View {
  @ObservedObject var model: DiffViewerModel
  let snapshot: DiffSnapshot

  var body: some View {
    List {
      ForEach(snapshot.sections.filter { !$0.files.isEmpty }, id: \.origin) { section in
        Section(header: Text("\(section.origin.label) (\(section.files.count))")) {
          ForEach(section.files, id: \.path) { file in
            row(origin: section.origin, file: file)
          }
        }
      }
      if snapshot.isEmpty {
        Text("差分はありません").font(.caption).foregroundStyle(.secondary)
      }
    }
    .listStyle(.sidebar)
  }

  // Why not onTapGesture: Section を持つ List では行の tap が拾われず、選択が変わらなかった (実測)。
  private func row(origin: DiffChangeOrigin, file: UnifiedDiffFile) -> some View {
    let selection = DiffViewerModel.FileSelection(origin: origin, path: file.path)
    return Button {
      model.selection = selection
    } label: {
      HStack(spacing: 4) {
        Text(file.changeKind.badge)
          .font(.caption2.monospaced())
          .foregroundStyle(file.changeKind.badgeColor)
        Text(file.path)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 0)
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .background(model.selection == selection ? Color.accentColor.opacity(0.18) : Color.clear)
  }
}

private struct DiffHunkView: View {
  let file: UnifiedDiffFile?
  let selection: DiffViewerModel.FileSelection?

  var body: some View {
    if let file {
      VStack(alignment: .leading, spacing: 0) {
        header(file)
        Divider()
        content(of: file)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    } else {
      ContentUnavailableView("ファイルを選択してください", systemImage: "doc.text")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func header(_ file: UnifiedDiffFile) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(file.path).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
      if let origin = selection?.origin {
        Text("出所: \(origin.label)").font(.caption2).foregroundStyle(.secondary)
      }
      if case .renamed(let from, let similarity) = file.changeKind {
        Text("rename: \(from) → \(file.path)\(similarity.map { " (\($0)%)" } ?? "")")
          .font(.caption2).foregroundStyle(.secondary)
      }
      if file.isSubmodule {
        Text("submodule (gitlink) の差分です").font(.caption2).foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(6)
  }

  @ViewBuilder
  private func content(of file: UnifiedDiffFile) -> some View {
    switch file.content {
    case .binary:
      note("binary ファイルのため差分行はありません")
    case .noContentChange:
      note("差分行はありません (mode 変更または rename のみ)")
    case .unreadable(let reason):
      note(reason.message)
    case .hunks(let hunks):
      // Why not ScrollView へ直接 frame: 両軸スクロールでは内容が viewport より小さいとき
      // 右下へ寄る (実測)。viewport の大きさを下限として内容側へ与え、左上に固定する。
      GeometryReader { proxy in
        ScrollView([.vertical, .horizontal]) {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(hunks.enumerated()), id: \.offset) { index, hunk in
              hunkHeader(hunk)
              ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                DiffLineRow(line: line)
              }
              if index < hunks.count - 1 { Divider() }
            }
          }
          .padding(.vertical, 4)
          .frame(
            minWidth: proxy.size.width, minHeight: proxy.size.height, alignment: .topLeading)
        }
      }
    }
  }

  private func hunkHeader(_ hunk: UnifiedDiffHunk) -> some View {
    Text(
      "@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@ \(hunk.section)"
    )
    .font(.caption2.monospaced())
    .foregroundStyle(.secondary)
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
  }

  private func note(_ message: String) -> some View {
    Text(message)
      .font(.caption)
      .foregroundStyle(.secondary)
      .padding(8)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

private struct DiffLineRow: View {
  let line: UnifiedDiffLine

  var body: some View {
    HStack(spacing: 0) {
      number(line.oldLineNumber)
      number(line.newLineNumber)
      // 横スクロール中の行なので、幅を親いっぱいへ広げず本文の長さのままにする。
      Text(line.kind.sign + line.text + (line.isMissingTrailingNewline ? " (改行なし)" : ""))
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.leading, 4)
      Spacer(minLength: 0)
    }
    .background(line.kind.background)
  }

  private func number(_ value: Int?) -> some View {
    Text(value.map(String.init) ?? "")
      .font(.system(.caption2, design: .monospaced))
      .foregroundStyle(.secondary)
      .frame(width: 34, alignment: .trailing)
      .padding(.trailing, 2)
  }
}

extension DiffChangeOrigin {
  var label: String {
    switch self {
    case .committed: "commit済み"
    case .staged: "staged"
    case .unstaged: "unstaged"
    case .untracked: "untracked"
    }
  }
}

extension UnifiedDiffLineKind {
  fileprivate var sign: String {
    switch self {
    case .context: " "
    case .added: "+"
    case .removed: "-"
    }
  }

  fileprivate var background: Color {
    switch self {
    case .context: .clear
    case .added: .green.opacity(0.15)
    case .removed: .red.opacity(0.15)
    }
  }
}

extension UnifiedDiffChangeKind {
  fileprivate var badge: String {
    switch self {
    case .added: "A"
    case .deleted: "D"
    case .modified: "M"
    case .renamed: "R"
    case .copied: "C"
    }
  }

  fileprivate var badgeColor: Color {
    switch self {
    case .deleted: .red
    case .added: .green
    default: .blue
    }
  }
}

extension UnifiedDiffUnreadableReason {
  fileprivate var message: String {
    switch self {
    case .binary(let byteCount): "binary と判定したため中身を読んでいません (\(byteCount) バイト)"
    case .tooLarge(let byteCount): "大きすぎるため中身を読んでいません (\(byteCount) バイト)"
    case .notReadable: "中身を読み取れませんでした"
    }
  }
}

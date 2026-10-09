import Adapters
import SwiftUI
import TerminalCore

/// Diff pane 上部の範囲表示 (設計書 §9.1)。
struct DiffRangeHeader: View {
  let summary: DiffRangeSummary

  var body: some View {
    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
      row("対象", summary.target)
      row("比較元", summary.comparison)
      row("起点", summary.origin)
      row("範囲", summary.contents)
    }
    .font(.caption)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
  }

  private func row(_ title: String, _ value: String) -> some View {
    GridRow {
      Text(title).foregroundStyle(.secondary)
      Text(value)
        .lineLimit(2)
        .textSelection(.enabled)
    }
  }
}

/// Base / Branch の比較先を選ぶ popover (§9.1)。
///
/// Why not `Menu`: 絞り込みの入力欄を置けない。ref が多い repository では平たいメニューから
/// 他のタスクの branch を探せない。
struct DiffRefPicker: View {
  let title: String
  /// popover を開いたときに読む。開いている間に一覧が変わっても追随しない。
  let tasks: () -> [DiffComparisonTask]
  let refNames: GitRefNames?
  let keyboardFocus: TerminalKeyboardFocus
  let choose: (String) -> Void

  @State private var isPresented = false

  var body: some View {
    Button(title) { isPresented = true }
      .buttonStyle(.borderless)
      .fixedSize()
      .popover(isPresented: $isPresented, arrowEdge: .bottom) {
        DiffRefPickerList(tasks: tasks(), refNames: refNames, keyboardFocus: keyboardFocus) {
          choose($0)
          isPresented = false
        }
      }
  }
}

private struct DiffRefPickerList: View {
  let tasks: [DiffComparisonTask]
  let refNames: GitRefNames?
  let keyboardFocus: TerminalKeyboardFocus
  let choose: (String) -> Void

  @State private var query = ""
  @FocusState private var isFieldFocused: Bool
  /// `DiffCommentPanel` と同じく、主張の持ち主を他の入力欄と区別するための識別子 (Issue #278)。
  @State private var claimant = UUID()

  var body: some View {
    let candidates = DiffComparisonCandidates(tasks: tasks, refNames: refNames, query: query)
    VStack(alignment: .leading, spacing: 6) {
      TextField("branch を絞り込む", text: $query)
        .textFieldStyle(.roundedBorder)
        .focused($isFieldFocused)
      List {
        if !candidates.tasks.isEmpty {
          Section("他のタスク") {
            ForEach(candidates.tasks, id: \.self) { task in
              row(task.branch) { taskLabel(task) }
            }
          }
        }
        if !candidates.localBranches.isEmpty {
          Section("local branch") {
            ForEach(candidates.localBranches, id: \.self) { name in
              row(name) { Text(name) }
            }
          }
        }
        if !candidates.remoteBranches.isEmpty {
          Section("remote branch") {
            ForEach(candidates.remoteBranches, id: \.self) { name in
              row(name) { Text(name) }
            }
          }
        }
        if candidates.isEmpty {
          Text("一致する branch がありません").foregroundStyle(.secondary)
        }
      }
      .listStyle(.inset)
    }
    .padding(8)
    .frame(width: 360, height: 400)
    .onAppear { isFieldFocused = true }
    // popover の入力欄も Drawer のテキスト入力と同じく、端末に first responder を取り返させない。
    .onChange(of: isFieldFocused) { _, focused in
      keyboardFocus.setTextInputClaim(focused, owner: claimant)
    }
    .onDisappear { keyboardFocus.setTextInputClaim(false, owner: claimant) }
  }

  // Why not onTapGesture: Section を持つ List では行の tap が拾われない (`DiffFileList` と同じ実測)。
  private func row(_ branch: String, @ViewBuilder label: () -> some View) -> some View {
    Button {
      choose(branch)
    } label: {
      label()
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
  }

  private func taskLabel(_ task: DiffComparisonTask) -> some View {
    HStack(spacing: 6) {
      Text(task.name)
      if task.branch != task.name {
        Text(task.branch).foregroundStyle(.secondary)
      }
      Spacer(minLength: 4)
      Text(task.directory)
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
  }
}

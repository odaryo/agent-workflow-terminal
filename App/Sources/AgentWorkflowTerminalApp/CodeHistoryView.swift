import Adapters
import SwiftUI
import TerminalCore

/// ファイル単位の Git 履歴と、選んだ commit 時点のコード / Diff (§7.3)。
struct CodeHistoryView: View {
  @ObservedObject var model: CodeHistoryModel
  let currentPath: String

  var body: some View {
    // Why not VSplitView: 一覧に上限を付けても分割位置は中央のままで、間に空白が残る。
    // 付けなければ一覧が高さの大半を取り、過去版の表示が数行になる (どちらも実測)。
    VStack(spacing: 0) {
      list
        .frame(height: 200)
      Divider()
      detail
        .frame(maxHeight: .infinity)
    }
  }

  @ViewBuilder
  private var list: some View {
    switch model.history {
    case .idle, .loading:
      ProgressView("履歴を読み込んでいます")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .failed(let message):
      CodeHistoryFailureView(title: "履歴を取得できません", message: message) {
        model.reloadHistory()
      }
    case .loaded(let history) where history.records.isEmpty:
      ContentUnavailableView(
        "履歴がありません", systemImage: "clock",
        description: Text("このファイルを含む commit がありません (未 commit のファイルなど)。"))
    case .loaded(let history):
      List {
        ForEach(Array(history.records.enumerated()), id: \.offset) { index, record in
          switch record {
          case .entry(let entry):
            CodeHistoryRow(
              entry: entry, currentPath: currentPath,
              isSelected: model.selectedEntry?.commitID == entry.commitID
            ) {
              model.select(entry)
            }
          case .failure(let failure):
            Label(
              "解析できない記録 (\(index + 1) 件目): \(String(describing: failure.error))",
              systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.orange)
          }
        }
        if history.hasMore {
          Button("さらに読む (\(history.limit) 件より前)") { model.loadMoreHistory() }
            .buttonStyle(.link)
            .font(.caption)
        }
      }
      .listStyle(.plain)
    }
  }

  @ViewBuilder
  private var detail: some View {
    if let entry = model.selectedEntry {
      VStack(alignment: .leading, spacing: 0) {
        detailHeader(entry)
        Divider()
        switch model.pastView {
        case .code: CodePastVersionView(model: model, entry: entry)
        case .diff: CodePastDiffView(model: model)
        }
      }
    } else if case .failed(let message) = model.pastVersion {
      CodeHistoryFailureView(title: "commit を表示できません", message: message, retry: nil)
    } else if case .loading = model.pastVersion {
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ContentUnavailableView(
        "commit を選択してください", systemImage: "clock.arrow.circlepath",
        description: Text("選んだ commit 時点のコードとその commit の Diff を表示します。"))
    }
  }

  private func detailHeader(_ entry: GitFileHistoryEntry) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      // Drawer のペインは約 240 pt しかない。固定幅の要素を1行に並べると、ペインより広がって
      // 左右が切れる (実測)。1行に1要素ずつ置く。
      Text("commit \(entry.abbreviatedCommitID) 時点")
        .font(.callout.monospaced())
        .fontWeight(.medium)
      Picker("過去版の表示", selection: pastViewBinding) {
        Text("コード").tag(CodeHistoryModel.PastView.code)
        Text("Diff").tag(CodeHistoryModel.PastView.diff)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()
      Button("現在の版に戻る", systemImage: "arrow.uturn.backward") { model.showCurrent() }
        .font(.caption)
      Text(displayText(entry.summary))
        .font(.caption)
        .lineLimit(2)
      if let path = entry.changes.first?.path, path != currentPath {
        Text("この commit 時点のパス: \(path)")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      if !isListed(entry) {
        Text("読み込んだ履歴の範囲外の commit です。")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var pastViewBinding: Binding<CodeHistoryModel.PastView> {
    Binding(get: { model.pastView }, set: { model.showPastView($0) })
  }

  private func isListed(_ entry: GitFileHistoryEntry) -> Bool {
    model.history.value?.records.contains { $0.entryValue?.commitID == entry.commitID } ?? false
  }
}

/// 行全体を Button にするのは、Accessibility 経由のクリックが `onTapGesture` には届かず
/// Button には届くため (CLAUDE.md の UI 計測の作法)。
private struct CodeHistoryRow: View {
  let entry: GitFileHistoryEntry
  let currentPath: String
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(entry.abbreviatedCommitID).font(.caption.monospaced())
          Text(entry.authoredAt.formatted(date: .numeric, time: .shortened))
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(displayText(entry.authorName))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
          if entry.isMerge {
            Text("merge").font(.caption2).foregroundStyle(.purple)
          }
          if let change = entry.changes.first, change.previousPath != nil {
            Text("rename").font(.caption2).foregroundStyle(.blue)
          }
        }
        Text(displayText(entry.summary))
          .lineLimit(1)
          .truncationMode(.tail)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .listRowBackground(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
  }
}

private struct CodePastVersionView: View {
  @ObservedObject var model: CodeHistoryModel
  let entry: GitFileHistoryEntry

  var body: some View {
    switch model.pastVersion {
    case .idle, .loading:
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    case .failed(let message):
      CodeHistoryFailureView(title: "過去版を取得できません", message: message, retry: nil)
    case .loaded(let past):
      content(past)
    }
  }

  @ViewBuilder
  private func content(_ past: CodePastVersion) -> some View {
    switch past.version {
    case .content(let result):
      if let text = result.text {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(notices(result: result, highlight: past.highlight), id: \.self) { notice in
            Label(notice, systemImage: "info.circle")
              .font(.caption)
              .foregroundStyle(.secondary)
              .padding(.horizontal, 8)
          }
          CodeTextView(text: text.content, highlight: past.highlight, highlightedLine: nil)
        }
      } else if let reasons = result.decision.confirmationReasons {
        FileOpenConfirmationView(reasons: reasons) { model.confirmOpenPastVersion() }
      } else {
        ContentUnavailableView("本文がありません", systemImage: "doc")
      }
    case .absent:
      note("この commit にはこのパスのファイルがありません。")
    case .symbolicLink:
      note("この commit ではシンボリックリンクのため、本文を読みません。")
    case .submodule:
      note("この commit では submodule (gitlink) のため、本文はありません。")
    case .exceedsAbsoluteMaximum(let byteCount, let maximum):
      note(
        "過去版のサイズが上限を超えるため取得しません (\(byteCount) バイト > \(maximum) バイト)。"
          + "現在の版と違い、先頭だけを表示することはできません。")
    }
  }

  private func notices(
    result: FileContentReadResult, highlight: FileContentLoad.HighlightOutcome?
  ) -> [String] {
    var notices = [FileViewText.summary(of: result.observation)]
    if let reasons = result.decision.confirmationReasons {
      notices.append(
        "確認のうえ表示しています: "
          + reasons.elements.map(FileViewText.message(for:)).joined(separator: " / "))
    }
    if let highlight, let message = FileViewText.message(for: highlight) {
      notices.append(message)
    }
    return notices
  }

  private func note(_ message: String) -> some View {
    ContentUnavailableView("本文を表示しません", systemImage: "doc", description: Text(message))
  }
}

private struct CodePastDiffView: View {
  @ObservedObject var model: CodeHistoryModel

  var body: some View {
    switch model.pastDiff {
    case .idle, .loading:
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    case .failed(let message):
      CodeHistoryFailureView(title: "Diff を取得できません", message: message, retry: nil)
    case .loaded(let diff):
      VStack(alignment: .leading, spacing: 0) {
        Label(baseDescription(diff.base), systemImage: "arrow.left.arrow.right")
          .font(.caption)
          .foregroundStyle(diff.base.isMerge ? Color.purple : Color.secondary)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
        if !diff.failures.isEmpty {
          Label(
            "Diff の一部を解析できませんでした (\(diff.failures.count) 件)",
            systemImage: "exclamationmark.triangle"
          )
          .font(.caption)
          .foregroundStyle(.orange)
          .padding(.horizontal, 8)
        }
        Divider()
        if diff.files.isEmpty {
          ContentUnavailableView("差分がありません", systemImage: "equal")
        } else {
          // 既存の Diff 表示をそのまま使う。選択もコメントも持たない model を渡すので、
          // 行のクリックは何もしない (コメントは Diff Viewer の機能、§9.2)。
          DiffHunkView(model: model.idleDiffModel, file: file(in: diff))
        }
      }
    }
  }

  /// rename の前後を両方 pathspec に渡すので、rename が検出されなければ追加と削除の2件になる。
  private func file(in diff: GitFileHistoryDiff) -> UnifiedDiffFile? {
    let path = model.selectedEntry?.changes.first?.path
    return diff.files.first { $0.path == path } ?? diff.files.first
  }

  private func baseDescription(_ base: FileHistoryDiffBase) -> String {
    switch base {
    case .emptyTree:
      "root commit のため、空の状態との差分です。"
    case .parent(let id):
      "親 \(id.prefix(7)) との差分です。"
    case .firstParentOfMerge(let id, let count):
      "merge commit (親 \(count) 個) のため、第1親 \(id.prefix(7)) との差分を表示しています。"
    }
  }
}

extension FileHistoryDiffBase {
  fileprivate var isMerge: Bool {
    if case .firstParentOfMerge = self { true } else { false }
  }
}

/// 失敗時は git の stderr をそのまま見せる (§7.3)。選択できるようにしておく。
struct CodeHistoryFailureView: View {
  let title: String
  let message: String
  let retry: (() -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(title, systemImage: "exclamationmark.triangle")
        .foregroundStyle(.orange)
      ScrollView {
        Text(message)
          .font(.caption.monospaced())
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      if let retry {
        Button("再読み込み", action: retry)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

/// author 名と summary は制御文字をそのまま含み得る (実測: ESC・US・RS が `%an` / `%s` に残る)。
/// 表示では Unicode の Control Pictures に置き換え、端末制御として解釈される余地も、見えない
/// 文字で別の内容に見せる余地も残さない。データ側は置き換えない。
func displayText(_ value: String) -> String {
  String(
    String.UnicodeScalarView(
      value.unicodeScalars.map { scalar in
        switch scalar.value {
        case 0x09: " "
        case 0x00...0x1F: Unicode.Scalar(0x2400 + scalar.value) ?? scalar
        case 0x7F: "\u{2421}"
        default: scalar
        }
      }))
}

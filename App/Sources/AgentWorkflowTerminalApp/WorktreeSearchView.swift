import Adapters
import SwiftUI
import TerminalCore

/// §8 の検索 UI。§6.1 が Drawer の内容を Code / Diff / Evidence の3種で確定させているため、
/// 独立したペインにはせず `.code` ペインの中に置く。
struct WorktreeSearchBar: View {
  @ObservedObject var model: WorktreeSearchModel
  @FocusState private var isFieldFocused: Bool

  var body: some View {
    VStack(spacing: 4) {
      HStack(spacing: 4) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
        TextField("検索", text: $model.term)
          .textFieldStyle(.roundedBorder)
          .font(.caption)
          .focused($isFieldFocused)
          .onSubmit { model.run() }
        if model.isRunning {
          ProgressView().controlSize(.small)
        }
        Button("実行", systemImage: "return") { model.run() }
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
          .disabled(model.term.isEmpty)
        if model.isShowingResults {
          Button("結果を閉じる", systemImage: "xmark.circle") { model.clear() }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        }
      }
      HStack(spacing: 8) {
        Picker("", selection: $model.target) {
          Text("全文").tag(WorktreeSearchTarget.fullText)
          Text("ファイル名").tag(WorktreeSearchTarget.fileName)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        Picker("", selection: $model.scope) {
          Text("gitignore を尊重").tag(WorktreeSearchScope.respectingGitignore)
          Text("全ファイル").tag(WorktreeSearchScope.allFiles)
        }
        .labelsHidden()
        .fixedSize()
        Toggle("正規表現", isOn: $model.usesRegularExpression)
          .toggleStyle(.checkbox)
          // ファイル名検索は部分一致固定 (§8.2 既定)。
          .disabled(model.target == .fileName)
        Spacer(minLength: 0)
      }
      .font(.caption)
      .controlSize(.small)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
  }
}

struct WorktreeSearchResultsList: View {
  @ObservedObject var model: WorktreeSearchModel
  let selectedPath: WorktreeRelativePath?
  let onSelect: (WorktreeSearchOpenTarget) -> Void

  var body: some View {
    VStack(spacing: 0) {
      ForEach(notices, id: \.self) { notice in
        Label(notice, systemImage: "info.circle")
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 8)
          .padding(.vertical, 2)
      }
      switch model.state {
      case .idle:
        Spacer(minLength: 0)
      case .running:
        ContentUnavailableView("検索中です", systemImage: "hourglass")
      case .failed(let error):
        // 「見つからなかった」ではなく「調べられなかった」(§12.3)。
        ContentUnavailableView(
          "検索できませんでした", systemImage: "exclamationmark.triangle",
          description: Text(message(for: error)))
      case .fullText(let report):
        if report.outcome.matches.isEmpty {
          ContentUnavailableView("一致する行はありませんでした", systemImage: "magnifyingglass")
        } else {
          List(report.outcome.matches) { match in
            fullTextRow(match)
          }
          .listStyle(.inset)
        }
      case .fileNames(let results):
        if results.matches.isEmpty {
          ContentUnavailableView("一致するファイルはありませんでした", systemImage: "magnifyingglass")
        } else {
          List(results.matches) { match in
            fileNameRow(match)
          }
          .listStyle(.inset)
        }
      }
    }
  }

  private func fullTextRow(_ match: WorktreeSearchMatch) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      HStack(spacing: 4) {
        Text(match.path.value)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.head)
        Text(":\(match.lineNumber)")
          .font(.caption2.monospaced())
          .foregroundStyle(.secondary)
        Spacer(minLength: 0)
      }
      HStack(spacing: 2) {
        Text(highlighted(match.line))
          .font(.caption.monospaced())
          .lineLimit(1)
        if match.line.isTruncated {
          Text("…")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .help("この行は \(WorktreeSearchLimits.maximumDisplayedColumns) 文字で切って表示しています。")
        }
      }
    }
    .padding(.vertical, 1)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(.rect)
    .background(selectedPath == match.path ? Color.accentColor.opacity(0.12) : Color.clear)
    .onTapGesture { onSelect(match.openTarget) }
  }

  private func fileNameRow(_ match: WorktreeFileNameMatch) -> some View {
    HStack(spacing: 4) {
      Image(systemName: "doc").foregroundStyle(.secondary).font(.caption2)
      Text(highlighted(match.path.value, range: match.range))
        .font(.caption)
        .lineLimit(1)
        .truncationMode(.head)
      Spacer(minLength: 0)
    }
    .padding(.vertical, 1)
    .contentShape(.rect)
    .background(selectedPath == match.path ? Color.accentColor.opacity(0.12) : Color.clear)
    .onTapGesture { onSelect(match.openTarget) }
  }

  private func highlighted(_ line: WorktreeSearchLine) -> AttributedString {
    var attributed = AttributedString(line.text)
    for range in line.matches {
      guard let lower = AttributedString.Index(range.lowerBound, within: attributed),
        let upper = AttributedString.Index(range.upperBound, within: attributed)
      else { continue }
      attributed[lower..<upper].backgroundColor = .yellow.opacity(0.35)
      attributed[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
    }
    return attributed
  }

  private func highlighted(_ text: String, range: Range<String.Index>) -> AttributedString {
    var attributed = AttributedString(text)
    guard let lower = AttributedString.Index(range.lowerBound, within: attributed),
      let upper = AttributedString.Index(range.upperBound, within: attributed)
    else { return attributed }
    attributed[lower..<upper].backgroundColor = .yellow.opacity(0.35)
    attributed[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
    return attributed
  }

  /// 打ち切り・取りこぼしはそれぞれ別の文言にする。全件を見せていると誤認させない (§12.3)。
  private var notices: [String] {
    switch model.state {
    case .idle, .running, .failed:
      return []
    case .fullText(let report):
      var notices: [String] = []
      if report.outcome.truncation.reachedResultLimit {
        notices.append(
          "先頭 \(WorktreeSearchLimits.maximumResultCount) 件だけを表示しています。ここに無い一致があります。")
      }
      let truncatedFiles = report.outcome.truncation.filesReachingPerFileLimit
      if !truncatedFiles.isEmpty {
        notices.append(
          "\(truncatedFiles.count) 個のファイルは1ファイルあたり "
            + "\(WorktreeSearchLimits.maximumMatchesPerFile) 件で打ち切りました。")
      }
      if !report.didFinish {
        notices.append("ripgrep が探索を完了していません。結果は途中までです。")
      }
      notices += sharedNotices(
        warnings: report.warnings, discarded: report.discardedOutOfScopeCount)
      if !report.parseFailures.isEmpty {
        notices.append("ripgrep の出力を \(report.parseFailures.count) 行、解釈できませんでした。")
      }
      return notices
    case .fileNames(let results):
      var notices: [String] = []
      if results.reachedResultLimit {
        notices.append("先頭 \(WorktreeSearchLimits.maximumResultCount) 件だけを表示しています。")
      }
      notices += sharedNotices(
        warnings: results.warnings, discarded: results.discardedOutOfScopeCount)
      return notices
    }
  }

  private func sharedNotices(warnings: String, discarded: Int) -> [String] {
    var notices: [String] = []
    let trimmed = warnings.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
      notices.append("調べられなかったパスがあります: \(trimmed)")
    }
    if discarded > 0 {
      notices.append("worktree の外を指す結果を \(discarded) 件捨てました。")
    }
    return notices
  }

  private func message(for error: RipgrepRunnerError) -> String {
    switch error {
    case .binaryNotFound(let candidates):
      "ripgrep (rg) が見つかりません。`brew install ripgrep` で導入してください。"
        + "探した場所: " + candidates.map(\.path).joined(separator: ", ")
    case .invalidWorktreeRoot(let url):
      "検索の起点が worktree の絶対パスではありません (\(url.path))。"
    case .tooManyResults(let limit):
      "結果が多すぎて読み切れませんでした (出力上限 \(limit) バイト)。検索語を絞ってください。"
    case .timedOut(let seconds):
      "\(seconds) 秒で終わらなかったため打ち切りました。"
    case .cancelled:
      "検索を中止しました。"
    case .commandFailed(_, let stderr):
      "ripgrep が実行できませんでした: "
        + stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    case .process(let error):
      "ripgrep を起動できませんでした (\(error))。"
    }
  }
}

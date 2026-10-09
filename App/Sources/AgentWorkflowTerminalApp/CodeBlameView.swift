import Adapters
import SwiftUI
import TerminalCore

/// working tree の内容に対する blame (§7.3)。注記は同じ commit が続く行の先頭にだけ出す。
struct CodeBlameView: View {
  /// Drawer のペインは約 240 pt。日付まで並べると注記だけで幅を使い切り、本文が横スクロールの
  /// 外に出る (実測)。日付は help に回す。
  private static let annotationWidth: CGFloat = 120

  @ObservedObject var model: CodeHistoryModel
  let isExpandable: Bool

  var body: some View {
    content
      .task(id: isExpandable) { startIfNeeded() }
  }

  @ViewBuilder
  private var content: some View {
    if !isExpandable {
      ContentUnavailableView(
        "blame を表示しません", systemImage: "doc",
        description: Text("§7.2 で本文をそのまま表示しないファイル (バイナリ・大きいファイル) には blame を出しません。"))
    } else {
      switch model.blame {
      case .idle, .loading:
        VStack(spacing: 8) {
          ProgressView("blame を計算しています")
          Button("取り消す") { model.cancelBlame() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .failed(let message):
        CodeHistoryFailureView(title: "blame を取得できません", message: message) {
          model.reloadBlame()
        }
      case .loaded(let rows):
        lines(rows)
      }
    }
  }

  /// blame を選んだ時点で本文の読み込みが終わっていなければ、`showBlame` は判定できずに何も
  /// 起動しない。本文が §7.2 で展開できると分かった時点で、ここから起動する。
  private func startIfNeeded() {
    guard isExpandable, case .idle = model.blame else { return }
    model.reloadBlame()
  }

  /// Why not `List`: 数千行で行ごとの選択・区切り線の描画が重い。Diff の表示と同じく
  /// 両軸スクロールの LazyVStack にし、viewport の大きさを下限として与えて左上に固定する。
  private func lines(_ rows: [CodeBlameRow]) -> some View {
    GeometryReader { proxy in
      ScrollView([.vertical, .horizontal]) {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(rows) { row in
            CodeBlameLineView(
              model: model, row: row, annotationWidth: Self.annotationWidth)
          }
        }
        .padding(.vertical, 4)
        .frame(minWidth: proxy.size.width, minHeight: proxy.size.height, alignment: .topLeading)
      }
    }
  }
}

private struct CodeBlameLineView: View {
  @ObservedObject var model: CodeHistoryModel
  let row: CodeBlameRow
  let annotationWidth: CGFloat

  var body: some View {
    HStack(spacing: 0) {
      annotation
        .frame(width: annotationWidth, alignment: .leading)
      Text(String(row.id))
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.secondary)
        .frame(width: 32, alignment: .trailing)
        .padding(.trailing, 6)
      Text(displayedContent)
        .font(.system(.caption, design: .monospaced))
        .fixedSize(horizontal: true, vertical: false)
      Spacer(minLength: 0)
    }
    .padding(.vertical, 1)
    .background(row.runIndex.isMultiple(of: 2) ? Color.clear : Color.secondary.opacity(0.08))
    .overlay(alignment: .top) {
      if row.annotation != nil { Divider() }
    }
  }

  /// CRLF のファイルでは行末に CR が残る (porcelain の本文行の実測)。
  private var displayedContent: String {
    row.content.hasSuffix("\r") ? String(row.content.dropLast()) : row.content
  }

  private func helpText(_ commit: GitBlameCommit) -> String {
    let date = commit.authoredAt?.formatted(date: .numeric, time: .shortened) ?? "日時不明"
    return displayText("\(date)  \(commit.summary ?? "")")
  }

  @ViewBuilder
  private var annotation: some View {
    if let annotation = row.annotation {
      let commit = annotation.commit
      if commit.isUncommitted {
        Text("未commit")
          .font(.caption2)
          .foregroundStyle(.orange)
          .padding(.horizontal, 6)
      } else {
        // 行から履歴項目へ移る。Accessibility 経由のクリックが届くよう Button にする。
        Button {
          model.showHistoryEntry(for: annotation)
        } label: {
          HStack(spacing: 4) {
            Text((commit.isBoundary ? "^" : "") + String(commit.commitID.prefix(7)))
              .font(.caption2.monospaced())
              .foregroundStyle(.blue)
            Text(displayText(commit.authorName ?? "(author 不明)"))
              .font(.caption2)
              .lineLimit(1)
          }
          .padding(.horizontal, 6)
          .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(helpText(commit))
      }
    } else {
      Color.clear.frame(height: 1)
    }
  }
}

import AppKit
import SwiftUI
import TerminalCore

struct DiffHunkView: View {
  @ObservedObject var model: DiffViewerModel
  let file: UnifiedDiffFile?

  private var selection: DiffViewerModel.FileSelection? { model.selection }

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
                DiffLineRow(model: model, line: line)
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

/// 行の選択 (§9.2 のコメント anchor 用)。click で単一行、shift + click でそこまでの範囲。
///
/// Why not context menu で範囲指定: **右クリックは context menu を開く前に行の tap gesture も
/// 発火させる** (実測: 別の行を選択した状態で対象行を右クリックし、メニューを Esc で閉じると
/// 選択がその行へ移っていた)。そのためメニュー項目の「ここまで広げる」は必ず自分自身までの
/// 1行になり、範囲にならない。shift + click は右クリックを経由しない。
private struct DiffLineRow: View {
  @ObservedObject var model: DiffViewerModel
  let line: UnifiedDiffLine

  /// context 行は old / new の両方に存在する。どちらへコメントするかを毎回問わず、
  /// 追加・context 行は new 側、削除行は old 側として扱う。
  private var side: DiffLineSide { line.newLineNumber == nil ? .old : .new }
  private var number: Int? { side == .old ? line.oldLineNumber : line.newLineNumber }
  private var isSelected: Bool {
    guard let number else { return false }
    return model.isSelected(line: number, side: side)
  }

  var body: some View {
    content
      .contentShape(.rect)
      .onTapGesture {
        guard let number else { return }
        // 修飾キーは gesture ではなく click 時点の実キー状態で見る。
        // Why not `TapGesture().modifiers(.shift)` との合成: `.exclusively(before:)` で組むと
        // **shift 無しの click まで届かなくなり、行が一切選べなくなる** (実測: 同じ画面で
        // Reviewing/Reviewed のラジオは合成クリックで切り替わるのに、行の tap だけ無反応)。
        if NSEvent.modifierFlags.contains(.shift) {
          model.extendSelection(to: number, side: side)
        } else {
          model.selectLine(number, side: side)
        }
      }
      .contextMenu {
        Button("選択を解除") { model.clearLineSelection() }
      }
  }

  private var content: some View {
    HStack(spacing: 0) {
      number(line.oldLineNumber)
      number(line.newLineNumber)
      // 横スクロール中の行なので、幅を親いっぱいへ広げず本文の長さのままにする。
      //
      // Why not `.textSelection(.enabled)`: 付けると**行の tap gesture が一切発火しなくなり、
      // コメントを付ける行を選べなくなる** (実測: 同じビルドでこの修飾子を外すだけで、
      // 同じ座標への HID クリックが `選択中: … new 41` へ変わった。行番号の桁を狙っても
      // 付いている間は無反応で、テキストの上だけの現象ではない)。§9.2 の行選択を優先し、
      // マウスでの本文コピーは落としている。
      Text(line.kind.sign + line.text + (line.isMissingTrailingNewline ? " (改行なし)" : ""))
        .font(.system(.caption, design: .monospaced))
        .fixedSize(horizontal: true, vertical: false)
        .padding(.leading, 4)
      Spacer(minLength: 0)
    }
    .background(isSelected ? Color.accentColor.opacity(0.35) : line.kind.background)
  }

  private func number(_ value: Int?) -> some View {
    Text(value.map(String.init) ?? "")
      .font(.system(.caption2, design: .monospaced))
      .foregroundStyle(.secondary)
      .frame(width: 34, alignment: .trailing)
      .padding(.trailing, 2)
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

extension UnifiedDiffUnreadableReason {
  fileprivate var message: String {
    switch self {
    case .binary(let byteCount): "binary と判定したため中身を読んでいません (\(byteCount) バイト)"
    case .tooLarge(let byteCount): "大きすぎるため中身を読んでいません (\(byteCount) バイト)"
    case .notReadable: "中身を読み取れませんでした"
    }
  }
}

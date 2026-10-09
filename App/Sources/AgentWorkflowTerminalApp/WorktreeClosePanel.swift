import SwiftUI
import TerminalCore

/// Close の確認をタブ列の下に出す。
///
/// sheet にしない。検査は未マージの branch で数秒かかり (Issue #366 の実測で 300 commit の走査に
/// 約 5 秒)、modal にするとその間タブの切り替えも端末への入力もできなくなる。
struct WorktreeClosePanelHost: View {
  @ObservedObject var closing: WorktreeClosing

  var body: some View {
    if let session = closing.session {
      WorktreeClosePanel(session: session)
        .id(ObjectIdentifier(session))
      Divider()
    }
  }
}

private struct WorktreeClosePanel: View {
  @ObservedObject var session: WorktreeCloseSession

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Close: \(title)").font(.headline)
      Text(session.target.worktreePath).font(.caption).foregroundStyle(.secondary)
      content
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.secondary.opacity(0.08))
  }

  private var title: String {
    session.target.branch ?? URL(fileURLWithPath: session.target.worktreePath).lastPathComponent
  }

  @ViewBuilder private var content: some View {
    switch session.phase {
    case .inspecting:
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("検査しています (未commit・未push・マージ済みかを確認しています。マージの判定には数秒かかることがあります)")
        Spacer()
        Button("取り消し") { session.close() }
      }
    case .inspectionUnavailable(let reason):
      Text(reason)
      actions(executable: nil)
    case .ready(let review):
      if let refusal = review.refusal {
        let text = WorktreeCloseRefusalText(refusal, progressFailure: review.progress.failure)
        Label("Close できません: \(text.reason)", systemImage: "nosign").foregroundStyle(.red)
        if !text.guidance.isEmpty {
          Text(text.guidance)
        }
        actions(executable: nil)
      } else {
        WorktreeCloseOptions(session: session, review: review)
        actions(
          executable: review.unavailability(of: session.option) == nil
            && (!review.requiresAcknowledgement(session.option) || session.acknowledged))
      }
    case .executing:
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("実行しています")
      }
    case .finished(let result):
      Text(result.headline).fontWeight(.medium)
      ForEach(Array(result.details.enumerated()), id: \.offset) { _, line in
        Text(line)
      }
      HStack {
        Spacer()
        if !result.closedWorktree {
          Button("再検査") { session.inspect() }
        }
        Button("閉じる") { session.close() }
      }
    }
  }

  /// `nil` なら実行ボタンを出さない。§3.4 の拒否は確認では済ませないので、押せない形でも出さない。
  private func actions(executable: Bool?) -> some View {
    HStack {
      Spacer()
      Button("再検査") { session.inspect() }
      Button("キャンセル") { session.close() }
      if let executable {
        Button("Close を実行") { session.execute() }
          .disabled(!executable)
          .keyboardShortcut(.defaultAction)
      }
    }
  }
}

private struct WorktreeCloseOptions: View {
  @ObservedObject var session: WorktreeCloseSession
  let review: WorktreeCloseReview

  var body: some View {
    ForEach(WorktreeCloseOption.allCases, id: \.self) { option in
      let unavailability = review.unavailability(of: option)
      Button {
        session.option = option
      } label: {
        Label(
          title(of: option),
          systemImage: session.option == option ? "largecircle.fill.circle" : "circle")
      }
      .buttonStyle(.plain)
      .disabled(unavailability != nil)
      if let unavailability {
        Text("選べません: \(unavailability)").font(.caption).foregroundStyle(.secondary)
          .padding(.leading, 22)
      }
    }
    if session.option.removesWorktree {
      let warnings = review.removalWarnings
      ForEach(warnings, id: \.self) { warning in
        Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
      }
      if session.option == .deleteBranch, let notice = review.squashDeletionNotice {
        Label(notice, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
      }
      if review.requiresAcknowledgement(session.option) {
        Toggle("上の内容を確認したうえで実行する", isOn: $session.acknowledged)
      }
    }
  }

  private func title(of option: WorktreeCloseOption) -> String {
    switch option {
    case .hideFromUI: "1. Inactive にするだけ (tmux session と worktree は残す)"
    case .terminateSession: "2. Inactive にし、tmux session を終了する"
    case .removeWorktree: "3. 2 に加えて、worktree を削除する"
    case .deleteBranch: "4. 3 に加えて、branch「\(review.target.branch ?? "")」を削除する"
    }
  }
}

import SwiftUI
import TerminalCore

@MainActor
struct ProjectAgentCommandSheet: View {
  let project: RegisteredProject
  @ObservedObject var projects: ProjectsModel
  @Environment(\.dismiss) private var dismiss
  @State private var input: String
  @State private var error: ProjectAgentCommandSaveError?

  init(project: RegisteredProject, projects: ProjectsModel) {
    self.project = project
    self.projects = projects
    // 呼び出し元の `AppModel.project` は Project を開いたときの写しで、保存後の値を持たない。
    // 古い値で開くと、そのまま保存しただけで設定を失う。
    let current = projects.registry.project(project.commonDirectory) ?? project
    _input = State(initialValue: current.agentCommand ?? "")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("「\(project.displayName)」の Agent 起動コマンド")
        .font(.headline)
      Text("hostctl worktree open の応答で Agent へ返します。コマンドの後ろに指示が1引数で付きます。空にすると未設定に戻ります。")
      TextField("claude", text: $input)
        .accessibilityLabel("Agent 起動コマンド")
        .onChange(of: input) { error = nil }
      if let error {
        Text(errorMessage(error))
          .foregroundStyle(.red)
      }
      HStack {
        Spacer()
        Button("キャンセル") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("保存") {
          error = projects.setAgentCommand(input, of: project.commonDirectory)
          if error == nil { dismiss() }
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
  }

  private func errorMessage(_ error: ProjectAgentCommandSaveError) -> String {
    switch error {
    case .invalid(.containsControlCharacter): "改行や制御文字は使えません"
    case .invalid(.tooLong): "150 バイトまでです"
    case .cannotSave: "Project の一覧を読み込めていないので保存できません"
    }
  }
}

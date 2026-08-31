# agent_workflow_terminal

AI Agentの開発ワークフローを、Git worktreeと永続的なTerminal sessionを軸に実行・確認・レビューするためのTerminalアプリケーションです。

> [!IMPORTANT]
> このプロジェクトは設計および技術検証中です。現在の仕様と技術構成は、PoCの結果により変更される可能性があります。

## Goals

- 1つの開発Taskを、1つのGit worktreeと1つのTask Tabとして扱う
- worktreeごとに独立したtmux sessionを保持する
- AI AgentのTerminalを中心に、必要なときだけCode、Diff、Evidenceを確認する
- Claude CodeやCodexなどをAgent Adapterで抽象化する
- Macを実行Hostとし、iPhone／iPadから同じ作業へ接続できるようにする
- Terminal本体とAgent Skillsの責務を分離する
- OSS公開時の著作権、ライセンス、ブランド境界を明確にする

## Status

Pre-alphaです。現在は次の技術的な成立性を優先して検証します。

1. SwiftUIへのlibghostty組み込みとtmux接続
2. iPhone／iPadからのSSH接続とTerminal描画
3. Claude Code／Codexの状態を共通化するAgent Adapter

## Documentation

- [Architecture and product specification](docs/architecture.md)

設計書では、会話で確定した仕様、現在の推奨構成、未確定事項、対象外の機能を区別しています。

## Planned Technology Stack

正式採用前の第一候補です。

- Swift 6
- SwiftUI
- libghostty
- tmux CLI
- git CLI
- SSH／SwiftNIO SSH
- SQLite／GRDB.swift
- ripgrep

## Contributing

外部Contributionの受け入れ方針は、最初のPoCと基本アーキテクチャの確定後に整備します。

現段階で提案や不具合報告を行う場合は、GitHub Issueを利用してください。

## License

This project is licensed under the [MIT License](LICENSE).

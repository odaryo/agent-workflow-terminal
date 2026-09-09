# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository state

`agent_workflow_terminal` is pre-alpha. It holds the design documents, one throwaway PoC spike, the core Swift package, and an initial macOS app target.

- `docs/architecture.md` — the specification (Japanese). `docs/coding-guidelines.md` — the coding rules; read it before writing Swift.
- `Spikes/gate1/` — the PoC Gate 1 spike (SwiftUI + libghostty + PTY + tmux). Throwaway code: excluded from lint, format, tests, and CI. Read it as a reference implementation; never copy code out of it.
- `AgentWorkflowTerminal/` — the SwiftPM package. Targets: `TerminalCore` (domain model, no UI/process deps) ← `Adapters` (external-world boundary, placeholder only). Each has a Swift Testing test target. Swift 6 language mode, strict concurrency.
- `App/` — the separate macOS SwiftPM package for the app and libghostty renderer. CI compiles it with a prebuilt `GhosttyKit.xcframework` downloaded from a Release asset; CI does not build the xcframework itself. There is no Xcode project. See `App/README.md`.
- **Tasks live in GitHub Issues — Issues are the single source of truth for *what* to do.** Never keep TODO lists in files, docs, or code comments; file an Issue instead.
- **Phase progress lives in `docs/roadmap.md`** — which phase is in progress, which Issue numbers remain to close it, and what is in flight. It is the only file that may reference Issues by number as a plan; it never restates Issue bodies or per-Issue status. GitHub milestones (`P1`〜`P5`, managed by `scripts/wf-milestone.sh`) are a mirror of the roadmap's phases for filtering Issues, not a second source. Update the roadmap when a phase closes, when a phase's Issue set changes, or when the in-flight Issue changes.

### Build / test / lint

```shell
cd AgentWorkflowTerminal && swift build && swift test     # CI 対象の core package
scripts/fetch-ghostty.sh                                  # CI / 通常開発用の事前ビルド済み libghostty
scripts/build-ghostty.sh                                  # ref 更新担当者向けの libghostty 自前ビルド
scripts/build-app.sh                                      # ローカルの macOS app bundle
```

初回導入と ghostty ref 更新では、対象ブランチ上で `App/ghostty-ref` の更新（初回は作成済み）→
`scripts/build-ghostty.sh` → `scripts/wf-ghostty-publish.sh` → 更新された
`App/ghostty-kit.sha256` を含むコミットと PR、の順に進める。publish より先に PR を開くと、
対応する Release アセットが無いため `build-app` ジョブは必ず失敗する。

```shell
# from the repository root
swift format lint --configuration .swift-format --recursive --strict \
  AgentWorkflowTerminal/Sources AgentWorkflowTerminal/Tests AgentWorkflowTerminal/Package.swift \
  App/Sources App/Package.swift
swift format format --configuration .swift-format --recursive --in-place \
  AgentWorkflowTerminal/Sources AgentWorkflowTerminal/Tests AgentWorkflowTerminal/Package.swift \
  App/Sources App/Package.swift
swiftlint lint --config .swiftlint.yml                    # requires `brew install swiftlint`
```

`swift-format` ships with the Swift 6 toolchain (no install); SwiftLint must be installed separately and is optional locally. CI (`.github/workflows/ci.yml`) runs `swift build` + `swift test` for `AgentWorkflowTerminal/`, compiles `App/`, and runs format/lint over both packages. The app job downloads a prebuilt `GhosttyKit.xcframework` from a Release asset, so CI does not require the toolchain that builds the xcframework (the SwiftLint job installs SwiftLint via brew if the runner image lacks it).

Domain logic and CLI-output parsers are written test-first with Swift Testing; UI rendering and libghostty integration are explicitly not unit-tested (spike + manual). See `docs/coding-guidelines.md`.

**Code = How / tests = What / commit log = Why / code comments = Why not.** Comments — `///` doc comments included — carry only what the code cannot: constraints, pitfalls, units, and design-doc section references. Never restate a name or a signature. See `docs/coding-guidelines.md` §8.

Documentation is written in Japanese; keep that language when editing docs. Commits follow Conventional Commits (`docs: ...`), with the *why* in the body.

### Repo operations (use scripts/)

| Operation | Script |
| --- | --- |
| Commit | `scripts/wf-commit.sh` |
| Publish the prebuilt GhosttyKit Release asset | `scripts/wf-ghostty-publish.sh` |
| Push | `scripts/wf-push.sh` |
| Sync `main` into a work branch | `scripts/wf-sync-main.sh` |
| Review diff (PR or branch) | `scripts/wf-review-diff.sh` |
| Create an Issue | `scripts/wf-issue-create.sh` |
| Comment on an Issue | `scripts/wf-issue-comment.sh` |
| Update Issue Project status | `scripts/wf-project-status.sh` |
| Create / close a milestone, assign Issues to one | `scripts/wf-milestone.sh` |
| Add / remove Issue labels | `scripts/wf-issue-label.sh` |
| Create a PR | `scripts/wf-pr-create.sh` |
| Edit a PR body or title | `scripts/wf-pr-edit.sh` |
| Merge a PR | `scripts/wf-pr-merge.sh` |
| Close a PR without merging | `scripts/wf-pr-close.sh` |
| Read / reply to PR comments | `scripts/wf-pr-comments.sh` / `scripts/wf-pr-reply.sh` |
| Clean up merged branches | `scripts/wf-cleanup-branches.sh` |
| Create a worktree | `scripts/wf-worktree-create.sh` |
| Remove a worktree and its local branch | `scripts/wf-worktree-remove.sh` |

Both agents and humans perform these operations through the scripts, never through raw `git`/`gh` write commands. If a request can't be expressed through a script, fix the script — don't route around it with a raw command.

Always invoke these from the repository root as `scripts/wf-*.sh <args>` — the `.claude/settings.json` allow rules are defined against that exact string form.

Task worktrees live at `<main-worktree-parent>/awt-worktrees/<slug>` by default; set
`AWT_WORKTREES_DIR` to override the parent directory. `wf-worktree-create.sh` writes only the created
path and a newline to stdout so callers can use it for `cd`; diagnostics go to stderr.

Merging is squash-only, with commit title `<PR title> (#N)` — so PR titles follow Conventional Commits too (`wf-pr-create.sh` and `wf-pr-merge.sh` both enforce this); `scripts/wf-pr-merge.sh` enforces checks-GREEN before it will merge.

## The product in one line

A macOS terminal app that runs multiple AI agents in parallel, one per Git worktree, each backed by its own persistent tmux session, with iPhone/iPad acting as thin remote clients to the same Mac host.

## Architecture constraints that shape all future code

These are recorded as **確定** (decided) in `docs/architecture.md` and should be treated as fixed unless the user changes them:

- **1 development task = 1 Git worktree = 1 task tab = 1 dedicated tmux session.** The Project Root gets its own separate permanent tmux session, outside the task-tab model.
- **The Agent Terminal is always the primary interaction UI.** All Agent panes' summaries and states can also stay visible in an independent Overview window (§13). P2 keeps the Viewer Drawer (max 2 panes); later Diff viewing must support a separate window, embedded or external (§1.2).
- **Do not reimplement tmux.** Pane splitting, key bindings, and session management stay in tmux; the app exposes only a minimal operation set (split, close, select, zoom) and reads pane/process/agent state.
- **tmux and git are driven as external CLI processes**, not as embedded libraries (no libgit2). Rationale: the app must observe the same entities the user sees in their own terminal, and version differences get absorbed at an adapter boundary.
- **Git is read-heavy, write-free.** Viewing (file browser, code viewer, diff, history/blame) is rich; commit/merge/rebase/worktree-creation is delegated to the agent or a plain shell. Worktree creation belongs to the agent because naming/placement rules are project-specific.
- **Agent-agnostic via `AgentAdapter`** (`ClaudeCodeAdapter`, `CodexAdapter`, process-detection fallback). Never build a Claude-Code-only feature. Normalized states are `Working / Question / Permission / Completed(Ready for Review) / Error / Idle / Unknown`, with tab priority `Needs Attention > Ready for Review > Working > Idle`.
- **`Unknown` is a first-class state.** When an adapter cannot determine state, never round it to `Working` or `Idle`.
- **Mac/PC is the only execution host.** No repositories, agent processes, or Docker on iOS devices; mobile connects over SSH and attaches to the same tmux session. Multiple devices may attach simultaneously with no input-exclusion mechanism.
- **Terminal core and Agent Skills stay decoupled.** The terminal must work as a plain terminal + worktree manager with no Agent Skills present, and must not invent phase state it cannot observe. Agent Skills must run without any terminal-specific API.
- **Single-user product.** One developer, their own Mac host, their own devices. No multi-user/team sharing, accounts, or permissions.
- **Remote reachability is delegated to the user's VPN** (e.g. Tailscale); the app only speaks SSH and ships no relay/NAT-traversal infrastructure. Structured data (agent state, diff, evidence) is available to mobile only while the Mac app (Host Core) is running — no standalone daemon; bare SSH + tmux attach still works without it.
- **Push notifications** use an opt-in lightweight relay to APNs with a minimal payload (worktree ID + notification kind; never code or terminal output). Without the relay, only local notifications while connected.
- **Diff review comments are sent to the implementation agent pane** (not the consultation pane). The consultation feature (`Ask Agent`, renamed from "Ask Claude") stays separate.
- **Agent Skills flow is a 4-phase pipeline** (requirements → design → implementation → independent review session, each with fresh context) as the final goal; per-phase details remain open.
- **Explicit non-goals:** full code editor/IDE, full Git client, GitHub PR review client, CI dashboard, tmux GUI replacement, web preview/DevTools, VNC, a custom chat UI built by parsing Claude Code output, a custom remote-terminal protocol, and any credential/SSH-key management (Git auth is fully delegated to the host environment).

## Planned stack (candidate, PoC-gated)

Swift 6 + SwiftUI, libghostty behind a `TerminalRenderer` protocol, tmux CLI, git CLI, SwiftNIO SSH for iOS, SQLite + GRDB (metadata only; large blobs on the filesystem), ripgrep CLI, and a small `hostctl` JSON-Lines CLI over separate SSH channels for structured data.

Everything in `docs/architecture.md` §21–22 is **現在の推奨** (leading candidate), not adopted — including Swift 6 / SwiftUI, so the SwiftPM scaffolding under `AgentWorkflowTerminal/` follows the recommendation and does not by itself make it 確定. The one exception is §21.5: Gate 1 passed on 2026-08-31 and libghostty for the **macOS** `TerminalRenderer` is now 確定 (the iOS renderer is not). Gates 2–5 in §24 are still unrun.

## Agent workflow (validated 2026-09-01)

Implementation tasks use a three-role pipeline, validated end-to-end on the tmux `list-panes` parser (3 rounds to converge; the pilot caught 2 Critical bugs in code that was fully GREEN).

**Roles**
- **Director** (the main Claude session): research, decisions, task decomposition, spec writing, progress judgment, reporting. Does not implement. Delegates read-only exploration and codebase lookups to the `explorer` subagent (`.claude/agents/explorer.md`, haiku).
- **Implementer** (the Opus subagent defined in `.claude/agents/implementer.md`): receives the Director's spec and edits files. **It only edits — it never commits or pushes**, so the Director independently verifies the changes and commits them. Follow-ups go back to the same agent via `SendMessage` so it keeps its measurements and context; a fresh agent re-derives what the last one already established. **Codex is no longer used** (user decision, 2026-09-07) — do not call `codex exec` for implementation, and do not treat a Codex fallback as available. `AGENTS.md` stays a thin pointer to this file and `docs/coding-guidelines.md`, never a second copy of the rules.
- **Reviewer** (an Opus subagent): adversarial diff review of each implementation commit. Must verify claims about external-CLI behavior by **measurement** (isolated resources — e.g. a dedicated `tmux -L` socket — cleaned up afterwards), not by reading code alone. A measurement that needs a process with a specific name (agent detection is name-based) needs a purpose-built binary: on macOS a renamed copy of a signed system binary such as `/bin/sleep` is SIGKILLed (exit 137) before it runs. Critical findings block completion. Its definition lives in `.claude/agents/reviewer.md`.

**The loop**
1. Director writes an Issue-style spec: 背景 / 要求 / スコープ (files allowed to change) / 完了条件 (the exact GREEN commands) / "on ambiguity or contradiction, stop and ask". Treat a reported workaround as a spec defect and widen the scope explicitly in the next round rather than blaming the implementer. The spec must forbid committing and pushing, because the implementer does neither.
2. Implementer delivers; Director independently re-runs the GREEN commands (cheap; trust but verify).
3. Reviewer reviews adversarially, classifying Critical / Major / Minor and separating code defects from **spec defects** (the pilot found both).
4. Critical findings go back to the implementer via `SendMessage` to the same agent as a fix spec. **Review findings are hypotheses**: any claim in a fix spec about external behavior must be re-verified by the implementer with a measurement before coding — the pilot's only regression came from implementing a reviewer's unverified premise. Continue looping while each round is backed by fresh measurement; escalate to the user when a round fails without new evidence or a design question emerges. **An agent's own "I measured it" is a claim, not evidence** — Issue #23 had an implementer's measured claim refuted by the reviewer, and two reviewers reach opposite conclusions from reading the same source. Ask for the method and the raw output, not the conclusion; when two rounds disagree, adopt neither and send it back to measurement.
5. Completion is reported only with GREEN + no Critical remaining — and at that point the Director merges (see **Merge authority**).

**Merge authority.** GREEN + no Critical remaining **is** the merge condition, and the Director acts on it — `scripts/wf-pr-merge.sh <PR>` **without waiting for the user's judgment**. The script mechanically verifies the rest (OPEN / non-draft / base=main / not CONFLICTING / checks complete and green), so the Director's own judgment reduces to one question: did an adversarial review run, and did it leave no Critical? For changes that skip the pipeline (below), GREEN alone is the condition. Escalate instead of merging when a Critical is unresolved, when no review was run on a change that needed one, when a design decision is still open, or when the user has said to hold that specific PR.

**When to skip the pipeline**: docs, config, and few-line mechanical changes — the spec+review overhead exceeds the value; the Director or a single subagent handles them directly. Anything that parses external output, touches state models, or crosses a module boundary goes through the full loop. **UI wiring in `App/` is reviewed by running it, not by the reviewer**: the layer is not unit-testable and measurement-based adversarial review has little to measure there, so the implementer attaches a manual-run check (screenshot in the PR) and only the `TerminalCore` / `Adapters` side of the change goes to the reviewer. **Drive that run with `scripts/verify-app-ui.sh`** (`build` / `launch` / `find` / `click-text` / `expect`, and `selftest` to check the harness itself) — it launches the bundle `scripts/build-app.sh` produced, locates elements through Accessibility instead of guessed coordinates, and closes the two traps that made Issue #230 a false alarm: a click on a non-active window is eaten by activation, and System Events clicks never fire SwiftUI's `onTapGesture` even though they do actuate Buttons.

**UI 層を計測するときの作法** (#278 の実測による)。

- **合成キーストロークは埋め込み端末 (libghostty の NSView) へ届く。** 以前「届かないので実キーボードを
  代表できない」と記録されていたが誤りで、`verify-app-ui.sh type` は端末へも入る (旧計測の null 結果の
  原因は特定できていない)。「実キーボードでしか測れない」と早々に諦めないこと。ただし System Events の
  制約で**非 ASCII は送れない**。逆に AX からは、libghostty の NSView が Accessibility 要素として
  現れないため「端末がフォーカスを持っている」と「どこも持っていない」を区別できない — フォーカスの
  所在は `focused` の戻り値ではなく**打鍵の到達先**で判定する。
- **tmux の pane を証拠に使うときは、一意なマーカーを1回だけ打つ。** pane はアプリの再起動をまたいで
  残るので、履歴と今回の打鍵を区別できない。#278 では「コメント欄と pane の両方に同じ文字列がある」
  状態が「2回打った」と「1回が両方へ入った」を区別できず、一意なマーカーで測り直して初めて判定できた。
- **打鍵の計測で Enter を送らない。** 修正前のビルドでは、コメント欄へ打ったつもりの文字列が生きた
  shell のプロンプトへ積まれていた。`verify-app-ui.sh type` は改行を含む文字列をコードで拒否する。

**外部 CLI を計測するときの作法** (#290 の実測による)。

- **tmux は未知の format 名をエラーにせず空文字にする。** `#{pane_bracket_paste}` は実在しないが、
  `display-message -p` は空文字を返し、`#{?pane_bracket_paste,ON,off}` は `off` を返す — 存在しない
  format 名を渡した対照実験と**完全に同じ挙動**である。つまり書き間違えた format は「観測できた false」
  として静かに通り、そこから導いた結論が監督の方針判断まで届く (#290 で実際に起きた)。**format を
  観測に使う前に、`list-formats` に在ることと、でたらめな名前が同じ値を返さないことを確かめること。**
- **コードベースが既に知っている制約を先に読む。** 上の件は `TmuxTextInjection.swift` の
  「アプリ側が 2004 を立てているかは tmux 3.4 の format に無く、注入側から観測できない」という注釈と、
  統合テストが**それゆえ prompt を zle の代理観測にしている**という注釈が、どちらも先に書かれていた。
  新しい観測手段を作る前に、対象のソースと既存テストの注釈を読むこと — 「観測できない」と分かっている
  ものを観測しようとしていないか。
- **外界の版数差は、想定より広いことがある。** #286 は「区切りが escape されない」として起票されたが、
  実測では tmux 3.7c が `\ooo` / named escape / `\$` の**いずれも生成しなかった** — 区切りだけの話では
  なかった。Issue 本文の記述を実測が上書きしたら、**Issue 側を訂正してから**進めること。
- **tmux の計測は `-L <一意な名前>` で隔離する。`TMUX_TMPDIR` を隔離手段にしない。** 2026-09-09 に
  ユーザーの既定 server が全 session ごと消えた。原因は #235 の対照実験の後始末
  `TMUX_TMPDIR="$TMUX_TMPDIR2" tmux -u kill-server` で、**`$TMUX` が `TMUX_TMPDIR` より優先して
  socket を決める**ため、tmux pane の中で動くレーンのこの行は隔離 server ではなく既定 server へ
  飛んだ (同じコマンド列でも server を起こす行だけは `env -i` が付いており、そちらは隔離できていた)。
  隔離側の server は生き残り、既定 server が死んだことが証拠である。`TMUX_TMPDIR` にはもう1つ罠が
  あり、**存在しないディレクトリを指していると tmux は黙って既定 socket へフォールバックする**
  (実測 tmux 3.4: 未作成のディレクトリを指した `list-sessions` がユーザーの session を返した。
  `TmuxRunner.swift` の realpath の注釈と同じ機序)。作り忘れ・`rm -rf` の後・typo のいずれでも、
  エラーにならずに既定 server へ着地する。なお**パスが長すぎる場合はエラーになりフォールバックしない**
  (実測: 202文字で `File name too long`) — 当初この節は「長さが原因」と書いていたが、レビューアの
  独立計測が否定し、再計測で覆った。原因は長さではなく不在である。
- **後始末は名前指定で消す。`kill-server` を既定 socket に届きうる文脈で書かない。** 消すのは
  `tmux -L <一時名> kill-session -t '=<作った名前>'` — `=` の完全一致で、自分が作ったものだけを撃つ。
  `kill-server` を使うのは、`-L` で隔離した socket に対してテストの後始末 (`IsolatedTmuxServer`) が
  撃つ場合に限る。`env -u TMUX` は行ごとに付ける — コマンド列の途中の1行だけ素の env に戻る書き方が
  今回の事故そのものである。
- **上の2項は規約だけでなくフックで機械的に止めている** (`.claude/settings.json` の `PreToolUse` /
  matcher `Bash` → `scripts/guard_bash_tmux.py`、Issue #314)。**`kill-server` は `-L` の有無に
  よらず一律に拒否**し (Bash から打つ正当な経路が無いため。`IsolatedTmuxServer` のそれは
  `swift test` プロセスの内部でフックからは見えない)、`kill-session` 系は「`default` でも
  `/` を含むパスでもない `-L` の名前」を伴わなければ拒否する。**`-S` (socket path の直接指定)
  を伴う `kill-se*` は、パスによらず一律に拒否**する — `-L` が良い名前でも `-S` があれば拒否
  (どちらが効くかを入力から決められないため、安全側へ倒している)。
  コマンド文字列が `kill-se` を含むときだけ解析し、その中で判定できないとき (引用符や
  コマンド置換の閉じ忘れ・上限 100 万文字の超過など) は拒否側に倒す。**hook JSON 自体が
  壊れているとき (不正 JSON / `tool_input.command` が文字列でない) は `kill-se` の有無に
  かかわらず拒否する** — つまり**壊れた JSON を受け取ると、あらゆる Bash 呼び出しが止まる**。
  判定不能を通さない以上そうなるが、止まる向きの事故として認識しておくこと。
  **timeout はここに含まれない**: 時間切れのフックはツール呼び出しを止めないので、下の
  「閉じられない穴」の側の話になる。判定は入力長に対して線形で、**試した 8 形では 99 万文字で
  0.06〜0.45 秒** (最悪はリダイレクトの連打。timeout 10 秒の約 22 分の 1)。これは試した形に
  ついての値であって上界ではない。
  **1 つのコマンド文字列の中で完結する再解釈は検査する** — `bash -c '…'` (`bash -euo pipefail -c`
  のように値を取るオプションを挟んだ形を含む)、`eval`、`env -S '…'`、`tmux -c '…'`、`$(…)`、
  プロセス置換 `<(…)` の中身は、それぞれコマンド文字列として同じ判定へ回す。一方で
  **シェルに文字列やファイルを食わせる形** (`bash <<EOF …`、`… | bash`、`bash /tmp/x.sh`)
  **は検査しない**: `bash script` がスコープ外である以上ここだけ塞いでも境界にならず、
  指摘が無限に増えるため。**拒否されたら別綴り (`kill-sess` / `kill-ser`) や
  別経路へ書き換えて再試行せず、隔離のほうを直すこと** — tmux はコマンド名の接頭辞一致を受け付けるので、
  書き換えて通そうとする動きはそのまま事故の再演になる。**逃し道は「ユーザーが Bash ツールの外で
  実行する」の1つだけで、コマンド文字列上のマーカーは用意していない** (マーカー方式は、拒否文と
  同じ文脈に綴りが現れるため「足せば通る」が最短経路として学習され、常用される)。既定 server への
  write が本当に必要ならユーザーに依頼する。フックが読まれるのは**セッションを起動した場所**の
  `.claude/settings.json` であり (`${CLAUDE_PROJECT_DIR}` は起動時のプロジェクトルートに固定され、
  Claude が worktree へ `cd` しても動かない)、**この変更を含まない worktree を起点に起動した
  セッションだけが無防備**になる。main で起動したセッションは古い worktree を触ってもガードされ、
  レーンは `scripts/wf-sync-main.sh` を通すまで無い。判定を変えたときは
  `scripts/check-tmux-kill-guard.sh` の fixture で確かめる (CI の `shell-guard`)。
- **フックの fail-closed には閉じられない穴が4つある。** 判定スクリプトが**無い** / **実行権が
  無い** / **timeout を超えた** / **`python3` が無くて起動できない** ときは、いずれもツール
  呼び出しが**そのまま実行される** (実測 2026-09-09: 存在しないパス・`chmod -x` した exit 2 の
  スクリプト・timeout 5 に対して 20 秒眠るスクリプトの3通りで、Bash ツールのコマンドが実行された。
  4つ目は判定本体を Python3 へ移したことで増えた同種の穴で、shebang が解決できなければ
  フックはそもそも起動しない)。フック側からは閉じられないので、
  **`chmod -x` や rebase 事故で黙って無防備になりうる**ことを前提に扱うこと — 「拒否されなかった」
  はガードが働いた証拠にならない。**判定本体の構文エラーもこの穴に落ちる**: python3 は
  構文エラーで exit 1 を返し (実測)、exit 2 以外は block しないので**ガードごと無効になる**
  — bash 実装では exit 2 になり全 Bash 呼び出しが拒否される逆向きの事故だったので、
  移行で向きが変わっている。CI の `shell-guard` が `py_compile` を別段で回すのはこのため。
- **観測の範囲を超えた一般化を書かない。** 上の1文は当初「3.7c は escape を一切行わない」と書いていたが、
  試した入力について「生成しなかった」ことしか測っていない。この差は次に読む人が「では escape は
  考えなくてよい」と判断できるかどうかを分ける。#286 では逆向きの実例も出た — spec が「保存段の escape は
  両版同一」と断じていたが、3.4 は保存段で `$` の前にも `\` を足す (実装者が検出、レビューアが独立再現)。

**Review findings and the roadmap.** Critical findings block the current Issue, as before. Major / Minor findings are filed as Issues in the legacy `P3 バグ改修` milestone (the parking lot, not the current P3) and do **not** count against the current phase. Promote findings when measured impact blocks a phase's acceptance criteria; data loss and incorrect input routing require evaluation even if everyday use has not reproduced them. The current P3–P5 and their acceptance criteria live in `docs/roadmap.md`. Measured 9/1〜9/6: each trunk Issue spawned ~3.4 derived Issues, none found by using the app; the parking lot prevents these from making a phase unbounded.

**Scope discipline** (applies to every role): no changes beyond the spec'd scope — no drive-by refactors or周辺整理. GREEN (build / test / lint) is a necessary gate, never evidence of quality; only adversarial review with measurement is.

**Session hygiene** (the Director's own session). Measured over 24h of transcripts: cost is ~52% cache read / ~37% cache write / ~11% output, so what the Director spends is set by **context length**, not by how much it writes. The per-request cache write is incremental and healthy — the leak is that a Director session grows monotonically (median 185k, peak 313k) because autocompact effectively never fires on a 1M window.

- **One Issue, one Director session.** The Director ends every Issue's final report with an explicit one-line request to run `/clear`, before the next worktree is created. This cannot be automated and the rule exists because the manual step was being forgotten: nothing in Claude Code lets the model invoke `/clear` or `/compact` itself, hooks (`PreCompact` / `PostCompact` included) can observe compaction but not trigger it, and autocompact (`autoCompactEnabled` / `autoCompactWindow`, default on) only fires as the context nears its limit — which the measurements above show a 1M window never reaches. Never `/clear` mid-Issue: the reviewer round-trip needs the Director's memory of what was already measured and rejected.
- **並列レーン運用では、監督が worktree を作る前にユーザーへ `/clear` を依頼する。** 監督 (main session) が
  worktree を作って隣の pane のセッションへ Issue を割り当てる運用では、上のルールの順序が壊れる —
  レーンが最終報告で `/clear` を要請した時点で、監督はもう次の worktree を作って次の Issue を渡している。
  レーンは規約に従って停止し (実測: 3回要請して停止したまま)、あるいは待つのをやめて規約を外れる。
  **順序は「レーンの完了報告 → 監督がユーザーへ `/clear` を依頼 → 打たれたのを確認 → 次の worktree を
  作って割り当て」**。`/clear` 後のレーンは文脈を失うので、割り当てメッセージは Issue 番号・worktree の
  パス・spec の在り処を含む自己完結した形にすること (spec が Issue コメントに載っていれば足りる)。
- **Do not `--resume` a large session left idle for over an hour.** The 1-hour prompt cache has expired and the first request rewrites the entire history: measured $2.06–$2.51 for a 200–233k resume, against $0.43–$0.65 to prime a fresh one. Start a new session and re-read what you need.
- **Never pass a `model:` override when calling a subagent on your own initiative.** The frontmatter is the decision (`reviewer` / `implementer` = opus, `explorer` = haiku); an override silently replaces it, and an accidental opus/fable exploration agent costs an order of magnitude more than `explorer`.
- **Read-only exploration goes to `explorer`, not `general-purpose`** — restating the Director's role above, because in practice this is the rule that gets skipped.
- **Never pass a `model:` override when calling a subagent unless the user names the model.** The frontmatter is otherwise the decision; a user asking for a specific model overrides it, and the report says which model ran.

**What survives a `/clear`.** Nothing is destroyed — the transcript persists and `/resume` still reaches it. What is lost is only what was loaded in context, and it has four kinds with four different homes. Getting this wrong produces a second, stale source of truth that contradicts the Issues.

| 種類 | 例 | 行き先 |
| --- | --- | --- |
| タスクの一覧・状態 | 何が Todo / In Progress か | **Issue + Project #6 のみ。** ファイルに書かない — 二重管理になる |
| Issue 内の一時記憶 | 計測結果、実装者へ渡した spec、棄却したレビュー仮説 | spec は **Issue コメント**、棄却した仮説とその理由は **PR 本文** |
| 横断的な学び | 「実装者の『計測した』は主張であって証拠ではない」 | **`CLAUDE.md` / `.claude/agents/*.md`。** 第二の規約集を別ファイルに育てない |
| 引き継ぎポインタ | 直前セッションの最終報告、in-flight の worktree / PR、次の着手候補 | **handoff ファイル** (下記) |

- **実装者へ渡す spec は、渡す前に Issue コメントとして投稿する** (`scripts/wf-issue-comment.sh`)。spec がセッション scratchpad にしか無いと、`/clear` で辿れなくなる — Issue #100 で実際に起きた。scratchpad はパスにセッション UUID を含み、公式ドキュメントに記載が無く、`/private/tmp` にあるため揮発する。
- **レビューで棄却した指摘は、棄却した理由とともに PR 本文に残す。** 次のラウンドや次の Issue で同じ仮説が再提出されるのを止められるのは、この記録だけ。
- **handoff ファイルは1セッション寿命・上書き専用・手で編集しない。** 読んで残す価値があるものは Issue / PR / CLAUDE.md へ移し、残りは捨てる。TODO を溜める場所ではない。
- handoff は `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/handoff/<key>/` に置かれる。`<key>` はセッション起動時のプロジェクトルート (`CLAUDE_PROJECT_DIR`) の絶対パスの `/` を `-` に置換し、元の絶対パスの SHA-256 先頭8文字を加えたもの。フォールバックが2つある — `CLAUDE_PROJECT_DIR` が無ければ cwd の `git rev-parse --show-toplevel` を使う (cwd は Claude に追従するので1セッションが複数 key に書き分け得る)、`shasum` が無ければハッシュ無しの key になる (別ディレクトリに着地するので過去の記録は読めない)。Stop / SessionEnd hook が直前セッションの最終応答を書き、次の startup / clear の SessionStart hook が読む。hook が自動で行うため Director の操作は不要で、人が実行してはならない。保存先全体は `AWT_HANDOFF_DIR` で差し替えられる。
- 同じ project root から起動した複数セッションは key を共有し、最後に終了したセッションの handoff が残る。`show` は記録時と現在のブランチが違えば1行警告するが、**検出できるのはブランチが変わった場合だけで、同じブランチで別の作業が上書きされたことは検出できない**。この `branch` は seal 時点の Claude の cwd 由来 (`cwd` は Claude に追従する) であり、key のアンカーである起動時の project root とは別物。
- `sealed_at` が7日より古い handoff は表示しない。休眠したプロジェクトで起動のたびに古い最終報告がコンテキストへ入るのを避けるため。ファイル自体は手で読める記録として残る。
- **`CLAUDE.local.md` は使わない。** 自動で読まれるが「指示」の位置に「状態」を置くことになり、古い引き継ぎが規約として効き続ける。加えてこの環境では実測で gitignore されていない — `core.excludesFile` が設定されているため `~/.config/git/ignore` の `**/CLAUDE.local.md` が参照されない。
- **Claude Code の auto memory はこのプロジェクトで採用しない。** 上表がすでに行き先を定めている — 棄却した仮説は PR 本文、横断的な学びは `CLAUDE.md` / `.claude/agents/*.md`。auto memory を足すとレビューで追えない第二の知識源になり、古い仮説が黙って効き続ける。

## Task tracking (GitHub Projects)

Issues are the single source of truth for tasks (see Repository state); [Project #6](https://github.com/users/odaryo/projects/6) is the board over them, and `docs/roadmap.md` holds phase progress (which phase, which Issues remain). One Issue = one worktree = one PR = one task tab. Milestones `P1`〜`P5` mirror the roadmap's phases; use them to filter, not to plan.

| Status | Meaning | Transition |
| --- | --- | --- |
| `Todo` | 未着手 | Issue Open 時 — 自動 (CI `project-status.yml`。Project 未追加の Issue は対象外) |
| `In Progress` | 実装中 | **worktree を作った時** — 手動 (`wf-project-status.sh`) |
| `In Review` | PR Open 済み・マージ待ち | PR Open 時 — 自動 (CI `project-status.yml`。draft は除外) |
| `Done` | マージ済み | PR マージ時 — 自動 (CI `project-status.yml`) |

`In Review` / `Done` は PR 本文の `Closes #N` に依存する。無ければ `In Progress` から先へ進まない。`Todo` の対象は「Open から30秒以内に Project #6 に載っている Issue」で、`wf-issue-create.sh` の `--project` (既定) はこれを満たす。`--no-project` で外したものは CI も board に載せない (item が現れるまで短くリトライし、現れなければ warning を出して何もしない)。既に Status が入っている item は上書きしない — Issue 作成直後に `In Progress` へ動かす通常フローと、遅れて届いた CI が競合して巻き戻るのを防ぐため。 **ProjectV2 の built-in automation は使わない** — Status option ID の再生成で全て無効化されており (下記 `updateProjectV2Field` 警告の事故と整合)、ProjectV2 workflow には公開 API が無く再有効化・変更が Web UI でしかできないため、リポジトリ内で管理できる CI (`.github/workflows/project-status.yml`) に置き換えた。CI からの Status 更新には `secrets.PROJECT_TOKEN` (classic PAT / `project` スコープ) が必要で、未設定の間は warning のみ出して成功する。

`In Review` exists so that **"手が動いているタスク"と"PR が出てマージを待っているタスク"が混ざらない** — agents run in parallel, so several tasks reach the PR stage at once. マージは Director が GREEN + Critical 無しで行う (上記 **Merge authority**) ため、通常この状態は短い。**長く留まっている PR は異常のサイン** — Critical が未解決か、設計上の決定を待っているか、ユーザーが明示的に保留した PR のいずれか。

**ユーザーを待つのは実装前の決定だけ。** マージはユーザーを待たないので、`In Review` はユーザー待ちを意味しない。実装前にユーザーの決定が要るものは `設計判断` ラベルを付け、`Todo` に置いたまま **決定待ち** ビューで分離する — ラベル付きの Issue は着手不可なので、`Todo` を「着手可能」の意味に保つための区別。決定して `/decide` で設計書に反映したらラベルを外す。ステータスは増やさない。

Views: `Board` (Status グループ) / `決定待ち` (`label:"設計判断" -status:Done`) / `View 1` (全件テーブル)。

**Never edit the `Status` field's options via `updateProjectV2Field`** — the mutation replaces the whole option list, regenerating every option ID and clearing the Status of every existing item. Add options in the web UI, or back up `gh project item-list --format json` first and restore afterwards.

## License policy

The app itself is MIT (decided; matches `LICENSE`). Dependencies: permissive only (MIT/BSD/ISC/Apache-2.0). GPL/LGPL/AGPL and unknown licenses are rejected by default — this is why Mosh is not embedded and tmux/ripgrep are used as external CLIs rather than vendored source. Do not copy code from other projects "for reference"; depend on it properly or implement clean-room. Avoid branding that implies an official Ghostty derivative.

## Project slash commands

- `/design-status <topic>` — look up a topic in `docs/architecture.md` and report whether it is 確定 / 現在の推奨 / 未確定 / 対象外. Use before implementing anything.
- `/decide <decision>` — promote an item to 確定 and update the doc body, §25/§31, and Appendices A/B consistently.

## Editing `docs/architecture.md`

The document deliberately separates four statuses: **確定** / **現在の推奨** / **未確定** / **対象外・不採用**. Preserve that distinction — do not promote a 現在の推奨 or 未確定 item to 確定 without the user saying so, and keep §25 (terminal open questions) and §31 (Agent Skills open questions) in sync when something is decided. Appendix A (decided checklist) and Appendix B (candidate checklist) also need updating when status changes.

Part I (terminal app) and Part II (Agent Skills / dev workflow) are intentionally kept separate; do not merge concerns across them.

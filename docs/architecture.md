# AI開発用Terminalアプリ 設計書

> 文書ステータス: 会話で確定した仕様の整理 + 未確定事項の明示
>
> 作成日: 2026-08-31
>
> 最終更新: 2026-09-07(目的の再確認。全paneの概要一覧、タスク完了の区別、通知優先のモバイル導入を反映)
>
> 参照会話: `AI開発フロー整理` (`6a9211a1-6a4c-83ec-9903-b3514cd9c595`)
>
> 開発名称: `agent_workflow_terminal`
>
> 正式プロダクト名: 未決定

## 0. この文書の読み方

この文書は、参照会話で検討した内容を次の4区分に分けて記録する。

| 表記 | 意味 |
|---|---|
| **確定** | ユーザー回答によって採用が明示された仕様、または後続の会話で明確に上書きされた最終仕様 |
| **現在の推奨** | 技術検討上の第一候補。実装決定ではなく、PoCに合格した場合の採用候補 |
| **未確定** | 会話で提案されたが、ユーザーによる採用確定がない内容、または詳細が未定の内容 |
| **対象外／不採用** | 実装しないこと、または後続の決定で撤回されたことが明確な内容 |

特に、次の2領域を混在させない。

- **Part I: Terminalアプリ本体** — Project、worktree、tmux、Viewer、状態検出、モバイル接続、ローカル保存など。
- **Part II: Agent Skills／開発フロー** — 要件定義、設計、実装、検証、成果物による引き継ぎなど。

TerminalはAgent開発フローの表示・操作・レビューを支援するが、Agent Skillsのオーケストレーターそのものにはしない。

---

# Part I. Terminalアプリ本体

## 1. プロダクト思想

### 1.1 確定した中核思想

本プロダクトは、単なるターミナルエミュレーターでも、AI専用IDEでも、Agentダッシュボードでもない。

> **Mac/PCを実行母艦として複数のAI Agentをworktree単位で並行稼働させ、人間がAgent Terminalを中心に、必要なときだけコード・Diff・Evidenceを確認し、どこからでも介入できるTerminalアプリ**

確定した設計原則は次のとおり。

1. **1開発Task = 1 worktree = 1タブ**とする。
2. 各worktreeは独立したtmux sessionを持つ。
3. UIの主役は常に**Agent Terminal**とする。
4. Code、Diff、Evidenceは必要時だけViewer Drawerで開く。
5. tmuxのpane構造と操作体系を活用し、独自のTerminal pane managerを再実装しない。
6. Claude Code専用アプリにはせず、Agent Adapterで複数Agentを扱う。
7. Gitの閲覧機能は強くするが、Git変更操作はAgentまたは通常Terminalに任せる。
8. Mac/PCを唯一の実行ホストとし、iPhone/iPadにはrepositoryやAgent実行環境を置かない。
9. Terminal本体とAgent Skillsを疎結合に保つ。
10. 復元・履歴・Evidenceは、worktreeがなくなった後も必要に応じて参照できるようにする。
11. **単一ユーザー**を前提とする。1人の開発者が自分のMac/PC hostと自分のデバイス群で利用する。

### 1.2 利用目的と優先順位 — 確定(2026-09-07)

第一の目的は、並行稼働するAgentセッションで何をしていたかを思い出す時間を減らすこと。
第二の目的は、人間の判断待ちを見落とさないこと。想定規模は3プロジェクト、各2〜3タスクで、
1タスク内の別paneにClaude CodeとCodexを含む複数Agentが動く。Agent内部のsubagent一覧は対象に含めない。

人間は要件・設計を質問に答えながら対話で確認し、PRレビューを行う。フェーズ進行とガードレールは
プロジェクト側ハーネスの責務であり、Terminalは目的・現在地・観測状態を表示する。
概要は「ログイン不具合を修正する｜設計相談中」程度とし、判断待ち・作業中・終了等は別のアイコンで表す。
全プロジェクト・全タスクのAgent paneを、タスクを切り替えずに一覧で確認できることを中核要件とする(§13)。

Diffは対象タスクと比較元を指定して別窓で閲覧したい。組み込み別窓と外部ツール連携はいずれも許容し、
方式は未確定。Gitツリー表示は追加候補であり必須ではない。編集はviや外部IDEで行う。
既存のViewer DrawerとP2の実装範囲は維持し、別窓への拡張は後続で扱う。

### 1.3 明示的に作らないもの

- 高機能なコードエディタ／IDE
- フル機能のGitクライアント
- GitHub PRレビュークライアント
- CIダッシュボード
- tmuxの完全GUI置換
- Chrome DevTools相当のWeb Preview
- リモートデスクトップ／VNC機能
- Claude Code出力を解析して再構成する独自Chat UI
- 独自Remote Terminal protocol
- Git認証情報、SSH鍵、アクセストークンの管理機能
- マルチユーザー／チーム共有機能(アカウント、権限管理、複数人での同一Host共有)
- 独自のリレーサーバやNAT越えインフラ(到達性は既存VPNへ委譲する)

## 2. 概念モデル

### 2.1 確定モデル

```text
Application
└─ Projects
   └─ Project
      ├─ Main / Project Root
      │  └─ permanent tmux session
      │     └─ panes
      │
      ├─ Active Worktrees
      │  └─ Worktree / Task Tab
      │     └─ dedicated tmux session
      │        ├─ Agent implementation pane
      │        ├─ Agent consultation pane
      │        ├─ shell pane
      │        └─ test/dev-server pane
      │
      └─ Inactive Worktrees
         └─ detected but not shown as normal task tabs
```

### 2.2 用語

| 用語 | 定義 |
|---|---|
| Project | Terminalに登録された1つのGit repository |
| Main / Project Root | worktree Taskとは別枠の、repository root用の常設作業空間 |
| Worktree | 1つの開発Taskを隔離するGit worktree |
| Task Tab | Active worktreeを開くためのUIタブ。1 worktreeと1:1 |
| tmux session | Mainまたは各worktreeに対応する独立した端末セッション |
| pane | tmuxが管理する分割領域。Agent、shell、test watcherなどを実行 |
| Agent Terminal | tmux paneに表示される通常のAgent TUI。アプリの中心画面 |
| Viewer Drawer | Code、Diff、Evidence、Consultationなどを必要時だけ表示する補助領域 |
| Active | 通常タブおよびOverviewに表示する現在作業中のworktree |
| Inactive | Git上には存在するが、通常の作業タブには表示しないworktree |

### 2.3 Project Rootの位置付け

Project登録時に、Project Root用の常設tmux sessionを作成する。

ただし**bare repositoryをProject Rootに持つレイアウトでは、Project RootをP1の対象としない**。`repo.git`の周りにworktreeを並べる運用ではProject Rootに作業ツリーが存在せず、タブのcwdもtmux sessionの作業ディレクトリも決められないためである。bare entryを除外する根拠は「安定IDを引けない」ことではない — bare repositoryでも`rev-parse --git-dir --git-common-dir`はrc=0で使える安定IDを返す(実測)。この場合Projectは`projectRoot == nil`となり、上位レイヤはProject Rootタブを持たないProjectを正常系として扱う(§3.2)。bare Projectへ作業ディレクトリを与えるかどうかは、Project Rootの常設session自体を実装する段階で改めて決める。

Project Rootは次の用途を持つ。

- repository全体の調査
- Agentへの実装前相談
- `+ New Task`の開始地点
- `CLAUDE.md`、`.claude/`、Agent Skills、各種設定ファイルの試験・変更
- 通常のshell作業

Git上は通常のrepositoryとして書き込み可能とし、Read-onlyにはしない。ただしTask worktreeとの誤認を防ぐため、UI上で明確に区別し、未commit変更があれば目立つ状態表示を行う。

Project Rootで変更した設定を既存worktreeへ同期する専用機能は作らない。commit、merge、rebase、cherry-pick、コピーなどはAgentまたは通常Terminalから行う。

## 3. worktree lifecycle

### 3.1 作成

worktree作成は原則としてAgent側が担当する。

理由は、branch名、配置ディレクトリ、命名規則、base branchなどがProject固有ルールに依存するためである。Terminal UIは`git worktree add`の業務ルールを持たない。

```text
User selects + New Task
        ↓
Mac host starts a normal interactive Agent
        ↓
User and Agent clarify the task
        ↓
Agent creates a worktree according to project rules
        ↓
Terminal detects the worktree
        ↓
Worktree is registered/activated
        ↓
Dedicated tmux session and Task Tab become available
```

モバイルからも`+ New Task`を開始できる。ただし、モバイルアプリ自身がGit worktreeを作るのではなく、Mac上のAgentを起動して同じフローへ入る。

### 3.2 検出とActive/Inactive

- TerminalはProjectに存在する全worktreeを検出する。
- 通常のTask TabにはActive worktreeだけを表示する。
- 既存・過去・別用途のworktreeはInactiveとして保持できる。
- AgentがInactive worktreeの再利用を提案した場合、Terminalは候補を表示するが、Active化は人が選択する。
- Active/InactiveはGit自体の状態ではなく、Terminalが保持するUI／運用状態である。
- 検出できたが作業ツリーへ到達できないworktreeは`到達不能`として保持する。

**`到達不能`はActive/Inactiveと直交する第3の軸ではなく、表示上はInactive相当として扱う。** タブは一覧から消さずに残し、グレーアウトして選択不可とする。attach先の作業ディレクトリが実在しない以上Active化できないが、可搬ボリュームやネットワーク共有へ置いたworktreeを`git worktree lock`することはgit自身が推奨しており、作業ツリーが一時的に消える運用は異常系ではなく通常運用に現れるためである。

**検出結果は「worktreeが消えた」と「今回は観測できなかった」を区別できる形で上位へ渡す。** 両者を同一視すると、ボリュームが戻ったときに同じworktreeが新規出現として扱われ、下記の自動Active化によってActive/Inactiveの区別が失われる。到達不能の間はTerminalが保持しているActive/Inactiveをそのまま保つ。

**アプリが観測している間に新規出現したworktreeは自動的にActive化する。** Project登録後の初回スキャンで見つかったworktreeはすべてInactiveから始め、自動Active化の対象は「観測中に新しく現れたworktree」に限る。`+ New Task`からAgentが作ったworktreeを人が改めて選ぶ手間を無くしつつ、登録時点で既に存在していた過去のworktreeが一斉にタブ化する事故を防ぐためである。

この自動Active化は新規出現だけに適用する。既存Inactive worktreeの再利用は上記のとおり人が選択する。

#### 3.2.1 アプリ停止中の増減

Active/Inactiveはアプリの再起動を跨いで復元する。復元した状態と起動直後のスキャン結果が食い違う場合、
**アプリが停止していた間は「観測中」に含めない**という一点から次の2つが決まる。

- 停止中に現れた (= 保存済み状態に無く、起動時のスキャンに在る) worktreeは`Inactive`から始める。
  自動Active化の対象は観測中の新規出現だけで、停止中の出現はそれに当たらない。
- 停止中に消えた (= 保存済み状態に在り、起動時のスキャンに無い) worktreeは保存済み状態から落とさず、
  `到達不能`として保持する。起動直後の1回目のスキャンは前回の観測を持たないため「削除された」と
  「一時的に到達できない」を区別できず、区別できないものをユーザーのActive指定を捨てる側へ倒さない。

到達不能として保持したworktreeは、以後の観測で再び見つかればそのときのActive/Inactiveをそのまま回復する
(§3.2の到達不能の規則と同じで、新規出現としては扱わない)。

### 3.3 Active化とtmux

Active化するworktreeに既存tmux sessionがあればResumeする。sessionがなければ、Terminalが自動作成せず、新規作成するか人に確認する。

worktreeのActive状態とtmux sessionの存在は独立して扱う。

### 3.4 完了とClose

Agentの実装完了やPR作成完了だけではworktreeをInactiveにしない。完了状態を表示し、PRレビュー後の追加修正を可能にする。

最終的に人が`Close`を実行したときだけInactiveへ移す。Close時には次の処理を選択できる。

1. UI上でInactiveにするだけ
2. Inactive化し、tmux sessionも終了する
3. Inactive化し、tmux sessionを終了し、worktreeも削除する
4. 3に加えて、対応branchも削除する

削除を選ばない限り、tmux sessionとworktreeは保持する。

**4はbranchがマージ済みの場合にだけ選択できる。** 未マージbranchの削除はTerminalから行わず、§17.2のとおりAgentまたは通常Terminalに委ねる。Closeの後始末としてのマージ済みbranch削除だけを例外として認め、任意のbranchを消せる汎用機能にはしない。

**「マージ済み」の判定は、ancestor判定(既定branchへfast-forwardで到達できるか)だけでなく、patch相当の
同一性(squash merge)も検出する — 確定(2026-09-08)。** squash mergeはancestor判定に現れない別commitとして
既定branchへ入るため、ancestor判定だけでは検出できず、未マージのbranchが誤って削除不可のまま残るか
検出漏れが起きる。判定は外部git CLIの出力に依存するため、実装時に隔離環境での計測で検証する。

**HEADがbranchを指していない(detached HEAD)worktreeでは、Closeそのものを拒否する — 確定(2026-09-08)。**
選択肢1〜4のいずれを選んでも実行せず、ブランチを作るか進行中のrebase／mergeを完了するよう促す。
下記の検査(警告して続行可)より強い扱いとして、確認では済ませない。

**3と4は実行前に未commit、未push、未mergeを検査し、該当すればユーザーへ警告して明示的な確認を求める。** 検査の結果は「実行を機械的に禁止する条件」ではなく、確認のうえ続行できる警告として扱う。gitの`worktree remove`はuntracked／変更ありを拒否するが、未pushと未mergeは止めないため、gitの失敗に任せるだけでは安全確認にならない。

| 検査 | 判定 |
|---|---|
| 未commit変更 | 対象worktreeに変更またはuntrackedファイルがある |
| ignoredファイル | 対象worktreeにgitignore済みのファイルがある |
| 未push | 対象branchがupstreamを持たない、またはupstreamより先行している |
| 未merge | 対象branchがProjectの既定branchへマージされていない |

**ignoredファイルを独立した検査にするのは、`git worktree remove`が`--force`なしでこれらを消すため
である。** 実測では、`.gitignore`済みの`.env`を持つworktreeが「変更なし」と判定され、
`worktree remove`はrc=0で`.env`ごと削除した。task worktreeがper-worktreeの`.env`やローカル設定を
持つのは普通の運用であり、「変更なし」と表示したまま消えるのは、この節が防ごうとしている事故
そのものである。

**ignored検査は他の検査と別のgit呼び出しで行い、その失敗を他の検査へ波及させない。**
`--ignored`を付けたstatusの出力は、`*.o`／`*.pyc`／`*.log`のようにファイル単位で一致するignore
パターンの下で際限なく増える(実測: ignoredファイル11,000件で8.56 MiB。`node_modules/`のように
ディレクトリ自身が一致する形は1レコードに畳まれるので増えない)。出力上限を超えると実行層は
切り詰めではなく失敗を返すため、1回のstatusに相乗りさせると、**ignoredの在庫が未commit検査を
道連れにする**。未commit検査は`git worktree remove`が実際に拒否する唯一の条件であり、ignoredの
量とは無関係に答えられなければならない。2回のstatusが別時点のworktreeを見ることは許容する
——どちらも実行を禁止する条件ではなく警告だからである。

**upstream設定を持ちながら追跡refが存在しない状態は、未pushともpush済みとも別の第三の状態として
扱う。** git status porcelain v2はこのとき`# branch.upstream`を出しながら`# branch.ab`を出さない
ため、先行しているかを答えられない。これを検査の失敗として扱うと毎回「検査に失敗しました」を出す
ことになるので、確定した状態として表示する。

この状態に落ちる原因は1つではない。上流branchが削除されて`git fetch --prune`が走った直後(PRが
マージされてユーザーがCloseを押す最も普通のタイミング)と、upstream設定だけあって一度もpushして
いない場合の**両方**がここへ来る。後者は未pushそのものである。gitの出力からこの2つを区別すること
はできない(実測。`status.aheadBehind`や`--no-ahead-behind`はporcelain v2では影響しない)ため、
**表示は「追跡先が消えた」と読める文言にせず、「追跡refが無く先行しているか判定できない」に留める。**
削除前の警告としてはどちらの原因でも出す。

**Projectの既定branchは`git symbolic-ref --quiet refs/remotes/origin/HEAD`で決め、得られなければ
main worktreeがその時点でチェックアウトしているbranchを使う。** remoteがあってもなくても決まり、
branch名を`main`／`master`などに決め打ちしない。`--quiet`を付けるのは、`origin/HEAD`が無いときに
素の`symbolic-ref`が`fatal:`とrc=128を返し、通常の失敗と区別できないためである(実測:
`--quiet`ではrc=1)。

`origin/HEAD`はgit 2.46以降`git fetch`が作成・更新するため、cloneしていないremoteでも最初のfetchで
生え、上流の既定branchの改名にも追従する(実測)。それでも陳腐化し得る経路は残るが、そのとき
main worktree側へ落とすと、一時的に別branchをチェックアウトしているmain worktreeで判定がずれる。
**`origin/HEAD`が値を返す限りその値を使い、main worktreeへは落とさない。**

**フォールバックするのは`origin/HEAD`が「無い」ときだけで、「壊れている」ときはしない。**
値が`refs/remotes/<remote>/`で始まらないなど解釈できない場合は、main worktreeへ落ちずに判定不能と
する。壊れた値を黙って捨てて別の答えを出すと、既定branchの出どころがユーザーに見えないまま
削除可否が決まる。

どちらの経路でも既定branchを特定できなければ、未mergeを「マージ済み」と誤って判定せず、
**判定不能として削除前に警告する**。

### 3.5 安定IDとtmux session命名

**worktreeの安定IDは、そのworktreeの管理ディレクトリの絶対パスとする。** 通常のworktreeでは`<git common dir>/worktrees/<name>`、Project Rootでは`<git common dir>`そのものである。

作業ツリーのパスやbranch名を識別子にしない。branchはworktree内で切り替えられ、作業ツリーのパスは`git worktree move`で変わるためである。管理ディレクトリ名はどちらの操作でも不変であることを実測で確認している。

tmux session名は安定IDだけから決定的に導出する。**作業ツリーのパスもbranch名も導出に使わない。**

```text
awt-<slug>-<安定IDのSHA-256先頭8桁>
```

`slug`は安定IDの最後のパス要素を、`[A-Za-z0-9_-]`以外の**Unicodeスカラをそれぞれ**`_`へ置換して
作る。通常のworktreeでは`git worktree add`時のディレクトリ名がそのまま残るため人が読める。

- 置換結果が`_git`になった場合に限り、一つ上のパス要素を使う。Project Rootの安定IDは
  `<git common dir>`、つまり通常`<repo>/.git`であり、そのままでは全ProjectのProject Rootが
  `awt-_git-<hash>`になって`list-sessions`から読めなくなるためである。判定は「`.git`由来か」では
  なく「置換結果が`_git`か」で行う。`.`は置換で消えるので由来を区別する情報が残らない。
- 置換結果が32文字を超えたら先頭32文字で切り詰める。識別はhashが担い、slugは人が
  `list-sessions`を読むためだけのものである。
- パス要素が1つも無いなど置換結果が空になる場合は`worktree`を使う。`awt--<hash>`は読めない。

置換をCharacter(書記素クラスタ)単位ではなくUnicodeスカラ単位で行うのは、書記素の分割規則が
Unicodeの版に依存し、**OSを更新すると同じ安定IDから別のsession名が出る**ためである。それは
この節が防ごうとしている二重session生成そのものになる。

導出元を安定IDに閉じるのは、**名前の決定性がResume(§3.3)の前提だから**である。作業ツリーの
basenameをslugに使うと、安定IDが不変であるはずの`git worktree move`で名前が変わり、移動後に
同じworktreeへ二重にsessionを作ってしまう。

Project Rootのsessionも同じ規則で導出し、別体系の命名規則を設けない。§2.3のとおりProject RootはTask worktreeと別枠だが、識別子としては同じ導出規則に載せたほうが衝突回避も再現も一箇所で済む。

`.`と`:`は生成名から必ず除外する。tmux 3.4の実測では、session名の`.`と`:`はどちらも`_`へ置換されて格納され、`a.b`と`a:b`が同一session名へ衝突する。さらに`has-session -t "=a.b"`は`.`をwindow指定として解釈するため、`.`を含む名前は完全一致でも引けない。

正規化とhashを組み合わせるのは、人が読める部分を残しつつ衝突を避けるためである。**session名は導出結果をそのまま使い、既存sessionと衝突した場合に連番などで回避しない。** 同じ安定IDからは常に同じ名前が出るという性質が、再起動後のResume(§3.3)の前提になる。

slugは`git worktree move`後に実際のディレクトリ名とずれ得る。管理ディレクトリ名は移動しても
作成時の名前のままだからである。可読性より決定性を優先した結果として受け入れる。

### 3.6 未確定事項

- `Close`後にActiveへ戻す具体的UI

## 4. tmuxモデル

### 4.1 確定仕様

- **1 worktree = 1独立tmux session**とする。
- 1 worktree内ではtmux windowを増やす運用を基本にせず、1 window相当の作業空間をpane分割して使う。
- pane分割はtmuxに任せ、Terminalアプリ独自のpane engineは作らない。
- Terminalはpane構成、実行中process、対応Agent、Agent状態を読み取る。
- 操作主体はtmuxのままだが、Terminal UIから日常操作を呼び出せる。
- tmuxのキーバインドもそのまま利用可能にする。
- **アプリはユーザーの既定tmuxサーバを使う**。専用socket(`-L`)へ隔離しない。

既定サーバを使うのは、ユーザーが素のターミナルから`tmux attach -t <session>`で同じsessionへ入れることを保証するためである。アプリが観測する実体と、ユーザーが自分の端末で見る実体を一致させることがこの製品の前提であり、専用socketではユーザー側が毎回`-L`を要求される。

代償として、session名前空間をユーザー自身のsessionと共有する。衝突回避は§3.5の命名規則が担い、サーバ全体へ波及する設定(`-g`)は使わない(§4.2、§4.4)。

Terminal UIで提供する操作は最小限とする。

- 縦分割
- 横分割
- paneを閉じる
- paneの選択／移動
- pane zoom
- 各操作のショートカット

window/sessionの高度な管理、名前変更、並べ替え、swap-paneなどを網羅する完全GUIは作らない。

paneへのテキスト注入方式は**`load-buffer` + `paste-buffer -p`**とする(§9.2、§10で使う)。`send-keys -l`はbracketed pasteで括る手段を持たず、本文の改行がそのまま実行になるため使わない。

注入は「送信」であって「実行」ではない。本文の改行をEnterとして実行させる機能はTerminalに持たせず、実行するかどうかはユーザーの明示操作として分離する。方式に伴う制約は§9.2.1にまとめる。

### 4.2 複数端末からの接続

同じtmux sessionをMac、iPhone、iPadから同時に表示・操作できる。独自の`Take Control`や入力排他制御は設けない。

複数クライアントからの同時入力が起こり得ることを前提とし、誤操作防止は将来のUX課題として扱う。

複数クライアントが同時attachしているときのwindowサイズは**`smallest`**とし、**Terminalが自分の作ったwindowに対して設定する**。サーバ全体のglobal option(`-g`)としては設定せず、ユーザーが自分で作った他のsessionへ波及させない。

`window-size`はtmuxのwindow optionである。tmux 3.4の実測では、`set-option -t <session> window-size smallest`が効くのはそのsessionの**現在のwindowだけ**で、後から作ったwindowは`latest`のままだった。§4.1のとおり1 worktreeは1 window相当で運用するが、windowを増やした場合はそのたびに設定する必要がある。

Gate 1で3方式を実測した(137x39のクライアントと199x56のクライアントを同一sessionへ同時attach)。

| `window-size` | 実測した挙動 |
|---|---|
| `smallest` | 79x20。全クライアントで全内容が見える。大きい側に余白が出る |
| `latest`(tmuxの既定) | 操作するたびに79x20と199x55が入れ替わる |
| `largest` | 199x55。小さい側でははみ出し、右下が見えない |

iPhone/iPadとMacの同時attachで**全クライアントが全内容を見られるのは`smallest`だけ**であり、大きい側の余白は許容する。既定の`latest`は「小さい端末を1回触るとMac側がその場で縮む」挙動になるため採らない。

### 4.3 サポートするtmux版数

サポート下限は**tmux 3.4**とする。3.4以上であれば機能制限を設けない。

3.5未満ではZWJを含むgrapheme(`👨‍👩‍👧‍👦`など)の表示幅をtmuxが誤る。Gate 1の実測では14ケース中1件のみで、tmuxを介さないlibghostty単体は14/14正解であり、原因はtmux側にある。実害は「該当絵文字が2セル余分に見える」「ZWJを`status-right`へ置くと右端に消し残しが出る」という表示上のものに限られ、機能欠損は無い。tmuxは3.5以降でgrapheme対応が改善している。

したがって3.5未満は**警告を出すのみ**とし、動作の制限や接続の拒否は行わない。3.4を切り捨てないのは、既存のCLI出力パーサの挙動根拠がすべて3.4の実測であり、Ubuntu 24.04 LTSの標準パッケージも3.4であるためである。

Adapterは版数を検出する。版数を解釈できなかった場合は`Unknown`として保持し、**「サポート対象」にも「対象外」にも丸めない**(§12.3と同じ方針)。

### 4.4 スクロールバック履歴とメモリ予算

**履歴はアプリとtmuxサーバの2か所に載る。** どちらの上限もTerminalが製品既定として明示し、ユーザーの`~/.tmux.conf`やghostty設定任せにしない。1 worktree = 1 tmux session(§4.1)を5〜10個同時に開く設計では、この既定値がそのままメモリ予算になるためである。

| 対象 | 製品既定 | 設定単位 |
|---|---|---|
| アプリ側scrollback | `scrollback-limit` = **10,000,000**(10MB) | surface単位 |
| tmuxサーバ側履歴 | `history-limit` = **10,000** | session生成時にsession単位で設定 |

`history-limit`はsession optionだが、**paneの履歴容量はpane生成時に確定する**。tmux 3.4の実測では、`new-session`のあとに`set-option`しても、そのsessionの最初のpaneは既定値(`2000`)のまま残り、以後に作ったpaneだけが新しい値になった。sessionを作ってから設定する素直な実装では、最初のpane —— つまり最も出力の多いAgent実装pane —— にだけ予算が効かない。Terminalは最初のpaneにも設定値が適用された状態でsessionを引き渡す。

どちらもアプリ設定から変更可能とする。tmux側は`window-size`(§4.2)と同じくsession単位で設定し、サーバ全体のglobal option(`-g`)としては設定しない。ユーザーが自分で作った他のsessionへ波及させないためである。

Gate 1のM4実測(`Spikes/gate1/README.md` §12.4〜§12.5)を根拠とする。

- **`scrollback-limit`(バイト)がほぼそのまま常駐メモリ増になる。** 既定の10MBで1 surfaceあたり最大+17MB、100MBにすると+103MB。上限に達すると頭から捨てられ、それ以上は増えない(上限として正しく機能している)。
- **tmuxの履歴メモリは`history-limit` × 行の桁数に比例する。** 174桁で1行あたり約2KB、`history-limit 10000`で1 paneあたり約25MB。**これはpane単位**であり、10タスク × 各数paneならtmuxサーバだけで数百MBに達しうる。
- アプリのメモリだけを見ていると全体像を見誤る。両方を製品として押さえる理由がこれである。

## 5. Agent Terminal中心UI

### 5.1 通常状態

通常はAgent Terminalだけを最大表示する。

```text
┌─────────────────────────────────────────┐
│ feature/payment                ●  ⚠  ↑2 │
├─────────────────────────────────────────┤
│                                         │
│            tmux / Agent TUI             │
│                                         │
│ > Implementing...                       │
│                                         │
└─────────────────────────────────────────┘
```

これは「Terminal中心」よりも厳密には**Agent Terminal中心**である。通常のshell、vim、dev serverなども同じTerminalとして自然に利用できる。

### 5.2 paneとAgent表示

- pane上には`Claude · Working`、`Codex · Needs Attention`、`zsh`など最小限の情報を表示する。
- 必要なときだけ、そのworktree内のAgent一覧を開ける。
- Agentが存在しないpaneも通常のTerminalとして扱う。
- Agentがいないworktreeの代表状態は`Idle`とする。`npm`やvimなど非Agent processをworktree代表状態へ昇格させない。

### 5.3 タブ表示

Task Tabには次を圧縮表示する。

- worktree名
- Agent代表状態
- Git状態を示す小さなマーク
  - uncommitted changes
  - clean
  - unpushed commits等

詳細なアイコン体系、色、アクセシビリティ表現は未確定。

## 6. Viewer Drawer

### 6.1 確定仕様

Code、Diff、Evidenceは常設せず、必要時にViewer Drawerとして開く。

```text
┌──────────────────────┬──────────────────┐
│                      │ Diff             │
│ Agent / tmux         │                  │
│                      │ User.php         │
│                      │ + ...            │
└──────────────────────┴──────────────────┘
```

- MacとiPad横画面では右Drawerを基本とする。
- 通常はAgent領域を縮めて並べる。
- 必要ならDrawerをAgent上へのOverlayに切り替えられる。
- ViewerだけをFullscreen表示できる。
- Drawerを閉じた時点がOverlayなら次回もOverlayで開き、InlineまたはFullscreenなら次回はInlineで開く。
- iPhoneでは基本的にFullscreen sheetとして表示する。
- Drawer内部は最大2分割とする。
- 2分割は左右または上下を選び、Code／Diff／Evidenceを任意に組み合わせる。
- Viewer側に自由な多分割レイアウトは持たせない。

### 6.2 Terminal出力からの遷移

Terminal出力で確実に認識できる対象をリンク化する。

| 対象 | 動作 |
|---|---|
| ファイルパス、行番号 | Code Viewerの該当位置を直接開く |
| URL | OSの外部ブラウザで開く |
| commit hash | Commit Diffを開く |

Agent固有の出力形式を深く解析せず、汎用的かつ誤判定の少ない対象だけをリンク化する。曖昧な文字列はリンクにしない。

PR、Issue、テスト結果、エラーをすべて専用UIへ変換する構造化出力パーサーは対象外とする。

## 7. File BrowserとCode Viewer

### 7.1 File Browser

現在のworktreeに存在する全ファイルを表示する。Git trackedだけには限定しない。

- trackedファイルは通常表示
- untracked／ignoredファイルはグレー等で区別
- modified／added／deleted等のGit状態を表示
- `node_modules`、`vendor`、build成果物、ログもアクセス可能
- 巨大ディレクトリの性能を守るため、ディレクトリはlazy loadする
- trackedファイルのGit状態はindex側とworktree側を分け、gitが返す状態を損失なく保持する。単一badgeではworktree側を優先し、worktree側が変更なしの場合だけindex側を表示する
- gitはディレクトリを追跡しないため、untracked／ignoredのdirectory entryに一致しないディレクトリはGit状態なしとする。配下の状態はディレクトリへ集約しない
- worktree root直下の`.git`は列挙しない。gitの内部保管庫であり作業ツリーのファイルではない（worktreeでは`.git`はディレクトリではなくファイル）。深い階層の`.git`という名前のユーザーファイルは隠さない
- サブモジュール配下はGit状態なしとする。`git status`はサブモジュールの中身を一切報告しないため、変更なしと主張できない（§12.3）。サブモジュールの所在はindexが正本なので`ls-files`のgitlinkから得る

### 7.2 大容量／バイナリファイル

- バイナリまたは大容量ファイルは、クリック直後に本文を展開しない。
- サイズ、行数、バイナリ判定を示し、`Open anyway`の確認を出す。
- 警告対象となるサイズ／行数は設定可能にする。
- デフォルト閾値は1 MiB／50,000行とする。バイナリは先頭8 KiBにNULバイトが1つでもあれば該当する。
- `Open anyway`を通しても先頭からの絶対上限までしか読まない。デフォルトは16 MiBとし、警告閾値と同じく設定可能にする。
- 絶対上限で打ち切った場合は、打ち切ったことを表示する。全文を表示していると誤認させない（§12.3）。
- バイナリは`Open anyway`を通しても本文を表示しない。v1でhexビューアは作らない。

### 7.3 Code Viewer

- 基本はread-only。
- 編集は外部エディタ、vim、Agentなどに任せる。
- ファイル変更を検知したら表示内容を自動更新する。
- 行または行範囲を選択し、コメントまたは`Ask Agent`を実行できる。
- ファイル単位のGit履歴を表示できる。
- 過去commit時点のコード／Diffを表示できる。
- blameを表示できる。
- 履歴上のコードを選択して`Ask Agent`へ渡せる。

軽量なsyntax highlightingは必要だが、v1でEditor engineやLSPを作ることはしない。

## 8. 検索

### 8.1 確定仕様

- ファイル名検索と全文検索を提供する。
- 検索専用DBやworktree別indexは必須としない。
- 検索範囲は常に現在のworktree内だけとする。
- 複数worktreeを横断する検索は提供しない。
- 検索結果から該当ファイル／行を開ける。
- 複数検索結果を選択し、ファイル、行番号、コード断片をfresh Agentへまとめて渡せる。

### 8.2 現在の推奨

全文検索はripgrep CLIをworktree rootで実行する。インデックス更新や削除時cleanupが不要であり、Git ignoreを尊重した検索と全ファイル検索を切り替えやすい。

次は**既定値**であり、設定可能なものとして扱う。確定仕様(§8.1)ではない。

| 項目 | 既定値 |
| --- | --- |
| scope UI | `gitignore を尊重`(ripgrepの既定動作)と`全ファイル`(`--no-ignore --hidden --glob '!.git'`)の2つ。`全ファイル`でも`.git`は常に除く。当初案の"Current directory"は採らない |
| 検索開始 | 明示実行(Enterまたは実行ボタン)のみ |
| debounce | 入れない。入力ごとの自動実行をしないため不要。実行中の再実行は前回をキャンセルする |
| 最大結果数 | 全体1,000件、1ファイルあたり100件。どちらで打ち切ったかを区別して結果に出す(§12.3) |
| 1行の表示幅 | 500文字。超えた行は切り、切ったことを結果に出す |
| 大文字小文字 | smart case(`-S`) |
| 正規表現 | 既定OFF(`--fixed-strings`)。UIで切り替えられる |
| バイナリ | ripgrepの既定に従いスキップする |
| symbolic link | 辿らない(ripgrepの既定。`-L`を付けない) |
| ファイル名検索 | `rg --files`の出力に対する、大文字小文字を無視した部分一致。scopeは全文検索と共有する |

ripgrepの`--max-columns` / `--max-columns-preview`は人間向けprinter専用のoptionであり、`--json`出力には効かない(ripgrep 15.2.0で実測)。表示幅の上限は出力を読む側で適用する。

ripgrepの`--json`は`--max-count`に達したことを出力しない。上限に達したファイルの`matched_lines`は上限値と一致するだけで、ちょうどその件数しか一致が無いファイルと区別できず、終了コードも0になる。打ち切りを推測ではなく確定させるため、`--max-count`には利用者へ見せる上限に1を足した値を渡し、上限+1件目が来たファイルを打ち切りと判定する。

`.git`の除外globに末尾スラッシュを付けない。`!.git/`はディレクトリにしかマッチせず、git worktreeの`.git`は`gitdir:`を書いた正規ファイルなので素通りする(ripgrep 15.2.0で実測)。「1タスク = 1 worktree」(§2.1)が確定仕様である以上、そちらが通常の実行環境になる。`!.git`は通常リポジトリの`.git/`配下も、worktreeの`.git`ファイルも両方除ける。

1実行あたりの出力上限は64 MiBとする。`--json`の1一致は実測で平均483バイトなので、汎用の実行層が既定とする8 MiBは約1.7万一致で尽き、1文字クエリが実際に超える。超過時は部分出力ごと捨てるため、1,000件上限が効くべき「一致が多すぎる」場面で0件になってしまう。64 MiBでも足りない木は実在するので、その場合は「結果が多すぎる」というエラーで返す。

検索は明示実行のみで、実行中の再実行は前回をキャンセルする。キャンセルは実際のripgrepプロセスの終了まで届かなければならない。`Task.detached`は新しいrootになりキャンセルを継承しないため使わない。

ripgrepが未導入の場合は検索だけが使えず、他の機能は動く。実行ファイルは`/opt/homebrew/bin/rg`、`/usr/local/bin/rg`、`/usr/bin/rg`の順に探す。

複数検索結果を選択してfresh Agentへまとめて渡す経路(§8.1)は未実装。

## 9. Diff Viewerとレビューsnapshot

### 9.1 Diff種別

次の3種類を提供する。

1. **Commit Diff** — 指定commitの変更
2. **Base Diff** — base branchとの差分
3. **Branch Diff** — 指定した任意branchとの差分

#### 9.1.1 base branchの決定

Base Diffのbase branchは次の順で決める。決めた結果はタスクタブごとに記憶し、次にDiffを開いたときは再判定しない。

1. そのworktreeのbranchのupstream (`@{upstream}`)
2. `origin/HEAD`が指す既定branch
3. どちらも解決できなければユーザーが選ぶ。判定不能をmainへ丸めない

ユーザーはいつでも明示的にbase branchを選び直せる。選び直した値が上の自動判定より優先される。

#### 9.1.2 Diff rangeの定義

Base Diffのrangeは**merge-base起点**とする。`git diff $(git merge-base <base> HEAD) HEAD`に相当し、
base branchが進んでもそのworktreeの変更だけが出る。base branch自身の進行分をレビュー範囲へ混ぜない。

Branch Diffも同じ定義に従う。Commit Diffは指定commitとその親の差分で、この規則の対象外。

#### 9.1.3 未commit変更の扱い

Base DiffとBranch Diffは、commit済みの変更に加えて**working tree・staged・untrackedをすべて含む**。
Agentが作業中の差分こそレビュー対象であり、含めなければこの機能の主用途が抜けるため。

snapshot内では出所を区別して表示する。区別はcommit済み／staged／unstaged／untracked／競合(unmerged)の
5種で、untrackedは新規ファイルとして全行追加で表示する。ignoredファイルは含めない
(§7.1のFile Browserがignoredを列挙することとは別の判断で、Diffは対象外)。

**競合(unmerged) — 確定(2026-09-08)。** マージ／rebase中の競合ファイルは一覧とDiffに表示するが、
**コメント送信の対象外**とする。解決が進むにつれて行が動くファイルにコメントanchor(§9.2)を張らない
ためである。§9.2のcomment anchorが持つ6要素の構造自体は変更しない。

**競合(unmerged)の情報源と本文 — 確定(2026-09-09)。** 競合ファイルの一覧は`git status --porcelain=v2`の`u`レコードから作る。`git diff`が出すcombined diff(`diff --cc`)と`git diff --cached`が出す`* Unmerged path`はどちらも通常のpatch形式と別物で、パーサは既知のレコードとして読み飛ばすだけにする — 「このパスは競合中」という一次情報はstatusが持っており、そちらだけを使う方が版数差に強い(git 2.50.1で実測: 競合中のパスは`git diff`／`git diff --cached`のどちらにも`diff --git`形式では現れず、unstaged側は`diff --cc`と`* Unmerged path`の両方を出す)。P2では**差分本文(combined diff)を表示せず**、一覧に競合中として出したうえで、開いたときに本文を表示しない理由を明示する。黙って空にしないことが要求であり、本文の表示方法は未確定として§25に残す。競合中でも`u`レコードのXY(例: `UU`／`AA`／`DU`)とstage 1/2/3のOIDは保持し、状態を「変更」へ丸めない(§12.3)。

### 9.2 コメント

- Diffの行または範囲にローカルレビューコメントを付けられる。
- コメント単体でAgentへ送信できる。
- 複数コメントをReview batchとしてまとめてAgentへ送信できる。
- GitHub PR reviewへの直接投稿は行わない。

コメントのanchorは`(snapshot ID, 出所, ファイルパス, 側 (old／new), 行範囲, 対象行のテキストハッシュ)`で表す。
**出所**は§9.1.3の区分のうちcommit済み／staged／unstaged／untrackedで、これが無いと行が一意に定まらない。
競合(unmerged)はコメント送信の対象外(§9.1.3)のため、anchorの出所には現れない。
§9.1.3が同じファイルの複数区分への同時出現を要求しており、区分ごとに内容の違う差分になるため、
`(snapshot ID, パス, 側, 行範囲)`だけではどの区分の行を指すか決まらない(隔離repoで実測)。
snapshotは§9.3のとおり不変なので出所まで含めれば行番号だけで一意に定まるが、テキストハッシュを併せ持つことで
Agentへ送る文面へ元コードを添える際にsnapshot本体を引かずに済み、記録が後から壊れていないことも検証できる。
ハッシュは新しいsnapshotへコメントを推測追従させるためのものではない (§9.3の禁止は維持する)。

コメントの送信先は、そのworktreeの**実装Agent pane**とする。Consultation paneへは送らず、相談機能とレビュー修正依頼の役割を分離する。
実装Agent paneは§12.7の**メインpane**と同一の登録先を指し、特定方法も§12.7に従う。未登録のworktreeでは送信操作を無効にし、
どのpaneへ送るかをTerminalが推測しない。

#### 9.2.1 テキスト注入の制約

送信は§4.1の`load-buffer` + `paste-buffer -p`で行う。tmux 3.4での実測にもとづき、次の3点を設計上の性質として扱う。§10の`Ask Agent`も同じ経路を使う。

1. **bracketed pasteが効くかは、受け側paneのその瞬間の状態で決まる。** tmuxが`ESC[200~`／`ESC[201~`で括るのはpane上のアプリがDECSET 2004を立てているときだけで、括らないときも本文のLFはCR(= Enter)へ変換して届く。つまり**送ったコメントが受け側次第で実行され得る**。同じアプリでも状態次第で変わり(bracketed paste対応のvim 9.1でも、normal modeでは注入したコマンドが実行された)、「このAgentなら安全」というアプリ単位の判断は成り立たない。DECSET 2004の状態はtmux 3.4のformatに無く、**注入側から観測できない**ため、これは残存リスクとして受け入れる。Terminalが塞げるのは`pane_in_mode`(copy-mode等)と`pane_input_off`だけである。
2. **bracketed pasteにescapeが無い。** 本文中の`ESC[201~`が受け側でpasteを打ち切り、残りが打鍵として届いて実行される。本文を黙って書き換えるとレビューコメントが壊れるため、tab／LF／CR以外のC0・DEL・C1を含むテキストは**加工せず拒否**して呼び出し側へ返す。
3. **注入テキストは一時的にディスクへ載る。** 外部プロセス実行層が子プロセスへstdinを渡さない方針のため`load-buffer -`が使えず、所有者だけが読める一時ファイルを経由する。

#### 9.2.2 送信可否の判定 — 確定(2026-09-08)

Diffレビューコメントの送信可否は、送信先paneの正規化状態で決まる。**送信を許可するのは
`Idle`と`Completed`(Ready for Review)の2状態だけ**とし、`Working`／`Question`／`Permission`／
`Error`／`Unknown`、および**そのpaneの状態エントリが存在しない場合**は送信操作を無効化して、
「先にpane側の処理を進めてから送信する」旨をUIに表示する。コメントは破棄せずUI側に保持し、
送信可能な状態になったら送れる。

理由:

- `Completed`のpaneは空の入力欄で次のプロンプトを待っており、`Idle`と同じ安全性を持つ。
  §9.2の主フロー(Agentが実装を終える → 人がDiffを見る → コメントを送る)はこの状態で起きるため、
  ここを不可にすると機能そのものが成立しない。**実測上、Agentが作業を終えたpaneは`Idle`ではなく
  `Completed`になる** — `Idle`は起動直後の限られた区間でしか観測されない(Gate 3、Issue #240)。
- `Question`はAgentの質問への回答欄、`Permission`は許可応答であり、コメント本文がそれらへの回答として
  解釈される。
- `Working`ではpaneのプロセス終了後にコメント本文がシェルのコマンドとして実行される(実測、Issue #240)。
- `Error`はAgentが落ちてpaneが素のシェルへ戻っている場合を含み、そのとき`Working`と同じ経路で
  コメント本文が実行される。
- `Unknown`は丸めない(§12.3で確定)ので送信不可側に置く。状態エントリが存在しない場合(ユーザーが
  素のシェルpaneをメインpaneに選んだ場合や、process fallbackがpaneを一覧に出さない場合)も同じ理由で
  送信不可とする。

許可集合は実装上も1箇所で定義し、UIの有効・無効と実際の送信経路が別々に判定しないこと。
二重判定は片方だけが直る抜け道になる。

送信を`Idle`と`Completed`に限定したことで、制約1(受け側次第で本文が実行され得ること)が及ぶ範囲は、
どちらも空の入力欄が次のプロンプトを待っている状態であり、人がAgentへプロンプトを送る通常の送信操作と
地続きになる。送信前に制約1を個別に警告するUIは不要と判断し、確定した
(§25に残っていた当該項目は解消)。

### 9.3 snapshot

Diffは開いた時点でsnapshotとして固定する。Agentが裏で変更を続けても、レビュー中の表示とコメント位置を自動で動かさない。

```text
Diff snapshot opened
        ↓
Agent changes files
        ↓
Viewer shows "files changed since this diff was opened"
        ↓
User selects Refresh
        ↓
New snapshot is created
        ↓
Old snapshot and comments remain in review history
```

Refreshは既存snapshotの上書きではなく、新しいsnapshotの作成である。古いコメントを新Diffへ推測追従させない。

### 9.4 Review状態

Diff snapshotにはシンプルな状態だけを持たせる。

- `Reviewing`
- `Reviewed`

Agentの実装サイクル、修正回、レビュー回の対応関係まではTerminal側で管理しない。

## 10. Ask AgentとConsultation Log

> 注: UI名称はAgent非依存の`Ask Agent`とすることで確定した(旧称: `Ask Claude`)。実行時にどのAgent CLIを使うかの選択方法は未確定。

### 10.1 質問の起点

次の対象から質問を開始できる。

- Code Viewerの選択行／行範囲
- Diffの選択範囲
- Evidence画像または注釈
- 複数の検索結果
- 過去のCode／Diff履歴

### 10.2 Consultation pane

- 各worktreeに相談用paneを1つ持つ。
- pane自体は再利用する。
- `Ask Agent`ごとのAgent sessionは原則fresh contextにする。
- 必要なら現在のconsultationを継続できる。
- 新規質問のデフォルトは`New conversation`とする。
- Agentはそのworktreeをcwdとして起動し、必要に応じて自由に他ファイル、Git履歴、テスト等を調査できる。
- Terminalは巨大なcontext builderを持たず、「何について質問したか」を起点情報として渡す。

PCでは回答を右サイドパネルに表示し、コード等を見ながら相談できる。iPhoneではsheet／overlay表示とする。これは独自Chat backendではなく、背後の通常Agent paneを別表現で見せる位置付けである。

### 10.3 Consultation Log

Agent sessionのresume履歴とは別に、TerminalがProject単位で永続保存する。

保存対象:

- 質問
- 最終回答
- 質問の起点Context
- 選択したコード／Diffのsnapshot
- Evidenceと注釈の参照
- commit hash、file path、line range等のGit参照情報
- 作成日時
- 元worktreeとそのActive／Closed状態

保存しないもの:

- Agent内部の全tool call
- 読み取った全ファイル一覧
- Agent sessionの完全ログ
- Gitにcommitする相談履歴ファイル

worktree削除後もsnapshotで当時の質問対象を確認できる。Git参照が有効なら、そのcommit時点のrepositoryへも辿れる。

過去ログから`Ask new question`を実行する場合は、過去sessionをresumeせず、fresh sessionを開始する。過去ログを新しい質問へ渡す場合は明示的に選択する。

## 11. 質問UIと通知

### 11.1 質問UIの優先順位

1. Agentネイティブの質問UIを最優先する。
2. AgentネイティブUIが使えない場合だけ、Terminal共通Questions UIをfallbackとして利用する。
3. TerminalはAgentの質問システムを置き換えない。

全worktree横断のQuestions Inboxは作らない。質問待ちはTask Tabの状態で把握し、対象worktreeを開いて対応する。

質問待ちタブを開くと、Terminal表示を維持したまま質問カードをoverlayする。閉じれば通常Terminal操作へ戻れる。

### 11.2 通知

通知はモバイル固有ではなく、Mac/PCとモバイルの共通機能とする。

対象は原則として、人間の対応が必要なイベントである。

- Question
- Permission
- Agent Error
- ハーネスが明示したタスク完了(§12.7)。paneの応答終了だけでは完了通知しない
- 長時間継続する`Unknown`

通知種別は個別にON/OFFできるようにする。

通知を開いた場合、対象worktreeだけでなく対応箇所までdeep linkする。

| 通知 | 遷移先 |
|---|---|
| Question | worktree → 該当pane → 質問overlay |
| Permission | worktree → 該当pane |
| Error | worktree → 該当pane／詳細 |
| タスク完了 | 対象worktree。明示的なレビュー対象がある場合はその対象 |

通知上でAllow／Denyなどを直接実行する機能は対象外とする。

Push通知は、APNsへ橋渡しする軽量な通知中継をopt-inで利用する方式とする(確定)。中継へ送るpayloadはworktree ID・通知種別などの最小限に留め、コードやTerminal出力を含めない。中継を有効にしない場合は、hostへ接続中のローカル通知のみとなる。中継の具体的な実装・提供形態(自前hosting等)は未確定。

**モバイル初版の利用条件は、Mac側アプリを起動したまま、外出先でiPhoneをロックし、
モバイルアプリを開いていない間にも判断待ちとタスク完了の通知が届くこと**とする。
通知中継を有効にした構成で検証する。どのAgent paneの判断待ちも対象にできることを要求する。
重複抑止、再接続時の再通知、通知から消失したpaneへ戻る場合の扱いは実装前に定める(§25)。

## 12. Agent Adapterと状態モデル

### 12.1 Adapter境界

TerminalにAgent Adapter層を持たせる。

```text
AgentAdapter
├─ ClaudeCodeAdapter
├─ CodexAdapter
└─ UnsupportedAgentFallback
        └─ process detection
```

各AdapterはAgent固有のhook、API、process、状態情報を利用し、Terminal共通状態へ正規化する。未対応Agentはprocess検出へfallbackする。

Agent Skill側からTerminal APIへの状態pushを必須にはしない。これによりTerminalとSkillsの密結合を避ける。

### 12.2 pane状態とworktree代表状態

pane単位ではAgent固有の詳細状態を保持できる。worktree全体には代表状態を1つだけ表示する。

大分類の優先順位:

```text
Needs Attention
    > Ready for Review
    > Working
    > Idle
```

`Question`、`Permission`、`Error`は`Needs Attention`として同列に扱い、その中では最終更新順とする。種類はアイコン等で区別する。

Agent完了は`Needs Attention`ではなく`Ready for Review`に分類する。

複数Agent paneがある場合でも、タブには最重要の代表状態を1つ表示する。paneごとの概要と状態は
worktreeを開かずにOverviewでも確認できる(§13)。この代表状態はpane観測の集約であり、
タスク全体の完了判定ではない。応答終了とタスク完了を混同しない表示へ後続で拡張する(§12.7)。

**代表状態の表示は安定化する。** Adapterの観測をそのままタブへ出すと、通常の作業中とアイドル中に表示が入れ替わり続ける(Gate 3記録のreplay実測: idle区間で11〜13回/分の`Idle`↔`Working`、working区間で19〜33回/分の`Working`↔`Unknown`)。この振動は**許容しない**。

- `Needs Attention`(`Question`／`Permission`／`Error`)および`Ready for Review`への遷移は**即時反映する**。人の対応が要る通知を遅らせない。
- `Idle`／`Unknown`へ**分類が変わって**入る遷移は、遷移元を問わず**9秒**保持してから反映する。保持中に、保持の対象でない分類(`Idle`／`Unknown`以外)または表示中の分類が観測されたら、保持を破棄してその観測を即時反映する。
- 保持の起点は、表示中の分類から離れた最初の観測時刻とする。保持中に`Idle`↔`Unknown`のように下位分類の間で値が変わっても**起点はリセットしない**(最後に観測した値を、最初の起点からの経過で反映する)。分類が変わらない変化(`Question`→`Permission`など)と`paneID`だけの変化は即時反映する。
- pane が1つも無い状態は、§5.2により表示上は`Idle`である。安定化でも`Idle`と同じ分類として扱う。別扱いにすると両者の往復がこの振動として表示に出る。
- 安定化は**UIへ出す代表状態にのみ適用**し、Adapterのevent stream(§12.4.1)が配信する観測そのものは加工しない。

9秒の根拠は、Gate 3の**生記録**57.4分(24 run)を実装済みAdapterへreplayした実測(2026-09-06、`Spikes/gate3/replay-swift/`)。生記録は容量のため追跡していないため、追跡している遷移列から再現すると時刻の量子化で一部の件数が1件ずれる(同ディレクトリのREADME)。分類器を書き直すと本物のAdapterと乖離するため、`ClaudeCodeAdapter`／`CodexAdapter`／`ProcessDetectionFallbackAdapter`をそのまま記録へ当てている。

- ちらつきの実体である`Working`の中断は、長さが0.25〜7.90秒に集中する(70件中64件)。次に長い中断は9.89秒で、**7.90〜9.89秒は空白帯**である。9.89秒以上の6件はcodexのターン間の実在のidle(約25秒)や画面が読めない区間(61.9秒)であり、潰してはならない。9秒は空白帯の内側に置いた値で、上下の余裕がほぼ均等(+1.10／-0.89秒)になる。
- 保持8.0／8.5／9.0／9.5秒は**いずれも表示遷移1.83回/分・実在の中断6件をすべて保持**で成績が変わらない。10秒にすると1.79回/分へわずかに下がる代わりに9.89秒のidleを潰すため、空白帯の外へ出す理由が無い。
- 9秒保持で表示遷移は4.43→1.83回/分になる。
- 保持時間を0〜30秒のどの値にしても、`Needs Attention`／`Ready for Review`の遷移時刻は保持なしの場合と一致する。保持時間を延ばしても人の対応が要る通知は遅れない。
- 数字は記録の250msサンプリング上のもので、**表示遷移の頻度は製品の予測値ではない**。Gate 3 §7.5は250msのpollingが成立しないと結論しており、`AgentObservationIntervals.signals`はこれより粗くなる。中断70件のうち55件が0.77秒以下なので、この粗さはベースライン側を大きく動かす。一方、閾値の根拠であるテール(7.90秒と9.89秒)はサンプリング間隔に対して頑健である。
- 保持を`Working`からの降格だけに限ると、`Idle`表示中に`Unknown`が一瞬入る往復が残る(5秒未満で入れ替わる`Idle`／`Unknown`表示が9秒保持で28回)。遷移元を問わない形にすると14回へ減る。これが遷移元を限定しない理由である。残る14回の大半は各runの先頭フレームで、画面の変化量を測る比較対象がまだ無く`Unknown`から始まることによる。
- ターン開始直後に`Working`を出せるかどうかは、画面テキストではなくpane単位の画面鮮度(Gate 3 §3.4、`Spikes/gate3/README.md`)で決まる。前ターンの完了マーカーは画面に残るため、画面テキストだけでは新しいターンの開始を`Ready for Review`と読んでしまう。実装済み`ClaudeCodeAdapter`を`claude-composite-r1`〜`r5`の生記録へ当てて真値区間と突き合わせると(`replay-swift --score`、真値区間と1.0秒のGUARDは`scripts/analyze.py`と同じ)、製品の`AgentObservationIntervals.signals`が使う2.0秒pollingで**working区間のrecallは0.995**、残る誤判定は**`Ready for Review`を1 poll分だけ先に出す2フレーム(443中0.45%)**だけである。250ms pollingではrecall 0.867で、取りこぼしは`Ready for Review`ではなくすべて`Unknown`になる。`Permission`区間の危険な誤判定はどちらの間隔でも0.000。**ターン開始直後の検出については、この0.45%を許容する**(許容条件そのものは§12.6・§25のとおり未確定である)。
- 同じpollingの粗さは、`Working`の検出率を上げる代わりに`Idle`の検出率を下げる。同じ`--score`出力で`Idle`区間のrecallは250msの0.892から2.0秒では0.763へ落ち、455フレーム中98が`Working`になる。さらに製品の`WorktreeRepresentativeStateStabilizer`(保持9秒)を同じidle真値区間へ当てると、GUARDを除いた23.0秒のうち表示が`Working`のままの時間が12.8〜22.5秒を占める(5 run×8位相、2.0秒polling)。
- 原因は、画面が変化した=出力があった、という仮定が成り立たないことである。250ms分解能で数え直すと、idle真値区間の独立した画面変化は**5 run合計10件で全件が1行**(GUARD 1.0秒。GUARDを外すと14件)であり、周期的な入れ替えではなく**起動直後に一回限りで起きるステータス行の遷移**がrunあたり2件あるだけである。**`completed-left`(ターン後の放置、55秒×5 run)の画面変化は0件**で、放置中の`Ready for Review`は元から正しく表示できていた。
- **この記録で測れているのは起動後25秒のidle区間だけである。** claudeの`idle`真値区間は各runに1本(25.0秒)しか存在せず、日常の長い待機はGate 3の記録に含まれない。以下の数字をその範囲を超えて一般化しない。
- 対策として、出力とみなす画面変化に**最小変化行数**を設けた。直前の観測とindex単位で比較して`AgentAdapter.minimumChangedLinesForScreenActivity`行以上違うときだけ鮮度を0へ戻す。既定は1(従来の挙動)で、2を宣言するのは`ClaudeCodeAdapter`だけである。2は推測ではなく実測の分離点で、250ms分解能ではidle側の画面変化10件が全件1行、working側は180件中99件が2行以上(`Spikes/gate3/README.md` §13.1)。codexはworking 196件中95件が1行だけの変化(spinnerのコマ送り)なので、同じ値を共有せず既定の1に据え置く。
- 再採点(同じ`replay-swift --score`、2.0秒polling、5 run×8位相の合算)では`Idle`区間のrecallが0.763→0.976になり、9秒保持を当てた表示でidle真値区間990.0秒のうち`Working`のままの時間が770.0秒(78%)→12.0秒(1.2%)、最長の連続が24.0→12.0秒へ下がる。代償はworking真値区間1084.0秒のうち表示が`Working`でない時間が4.0→60.0秒(5.5%)で、行き先は`Ready for Review`側の危険側でない誤りである(recall 0.995→0.953)。`Permission`区間の危険な誤判定は0.000のまま、`Permission`のrecallも1.000で変わらない。**保持9秒と保持の対象範囲は変更していない。**

### 12.3 Unknown

Agent processの存在は確認できるが、Adapterが状態を確定できない場合は推測で`Working`や`Idle`へ丸めず、正式な`Unknown`状態とする。

- 一時的な`Unknown`では通知しない。
- 設定可能な時間を超えて継続した場合に通知する。
- 会話では約10分が初期値候補として示されたが、デフォルト値は最終確定していない。
- `Unknown`からAdapter名、最終成功時刻、エラー詳細を確認できる。
- Agentそのものの失敗とAdapterの状態取得失敗を混同しない。

### 12.4 Adapter API形状

**確定(2026-09-03)。** 根拠はPoC Gate 3の実測(§24、`Spikes/gate3/README.md`)。

#### 12.4.1 状態取得はevent購読を基本形とする

`AgentAdapter`の主APIは、pane単位の状態観測を流し続けるevent streamとする。pollingするかどうかはAdapter内部の実装詳細であり、API面には出さない。

根拠: 信号ごとに最適な取得頻度が違う。hookはeventとして届き、tmux formatはpollingで読み、process観測は高コストで低頻度にしたい。呼び出し側が単一の間隔を決める形にすると、この差を吸収できない。

#### 12.4.2 生存確認と状態観測を分ける

「Agent processが存在するか」の確認と、「そのAgentがどの状態か」の観測を別APIとする。

根拠は2つ。

- process table全走査の実測コストが、tmuxからの状態取得の8倍あり、観測コストを支配する。両者を1つの呼び出しに束ねると頻度を分けられない。
- Agent processを強制終了しても、paneには直前の描画が残り続ける。画面由来の判定は、生存確認を先に通していないと死んだAgentの状態を出し続ける。

**`Agent processが居ない`は`Unknown`ではない。** §12.3の`Unknown`はprocessの存在が確認できている場合に限る。

#### 12.4.3 種別不明の注意状態を表現できるようにする

状態観測の結果には、`AgentState`とは別に§12.2の大分類を持たせる。種別まで確定できなくても「注意が要る」ことだけは伝えられるようにするためである。

根拠: Agentによっては「操作待ちである」ことだけを外部へ出し、それが`Permission`なのか`Question`なのかを区別できない形で提供する。この場合に`Unknown`へ丸めると、Tier上取得できている情報を捨て、`Needs Attention`として通知できなくなる。

`AgentState`の7状態の語彙自体は変更しない(§12.2、§12.3)。

#### 12.4.4 `Unknown`の理由は型で持つ

`Unknown`には理由を列挙型で持たせ、表示専用の文字列とは分ける。

根拠: 「画面を読めない」「信号が存在しない」「Adapterが判断できない」はUIでの扱いが別物である。文字列だけで持つと、UI側が理由で分岐したくなった時に文字列解析が必要になる。§12.3が要求する「Agentそのものの失敗とAdapterの状態取得失敗を混同しない」も、型で持って初めて機械的に守れる。

### 12.5 Adapterが使う信号の採用基準

Adapterが状態判定に使ってよい信号は、**PoC Gate 3の記録で採点され、`Spikes/gate3/README.md` §6の混同行列に検出率・誤判定率の数字が残っているものに限る。** 「スパイクの記録に写っている」ことは採用根拠にならない。

採点されていない信号を使いたい場合は、`Spikes/gate3/scripts/analyze.py`の分類器へ加えて記録をreplayで再採点し、混同行列を更新してから採用する。記録は保存されているため再採点は安価である。**コード上の根拠コメントで代替することは認めない。**

ただし「再採点は安価」が成り立つのは、**その信号が記録に写っている場合だけ**である。Gate 3の記録は`capture-pane -p`で採っており文字属性(SGR)を持たないため、**属性に依存する信号は既存記録では再採点できず、対象を絞った再記録が要る**。Issue #217のdim属性(Claude Codeの入力欄で、プレースホルダと利用者の入力を分ける唯一の手掛かり)がこれに当たり、recorderを`capture-pane -e -p`へ変えてClaude Codeのcompositeシナリオだけを現行版で採り直したうえで採用した(`Spikes/gate3/README.md` §6.4。旧版の行は版数ドリフトの記録として残してある)。

この基準は、採点していないルールを足したことで`working`の検出率が下がり`idle`が上がるトレードオフが、commitにも仕様にも根拠を残さないまま入っていた実例を受けたものである。今後のAdapter実装の完了条件はこの節を参照する。

信号の**組み合わせ方**(どの信号をどう合成して7状態へ落とすか)は各Adapterの実装判断であり、この基準は個々の信号の採用可否だけを縛る。

### 12.6 状態遷移の未確定事項

- `Permission`、`Question`、`Completed`、`Error`の厳密な検出条件(Gate 3で取得可否は実測済み。`Question`に相当する状態を持たないAgentがあること、ターン中のAPIエラーが未計測であることを含む)
- PR Readyの検出元
- Adapter eventの永続化期間
- false positive／false negativeの許容条件(表示の振動を許容しないこと、およびターン開始直後のfalse positiveは§12.2で決着済み)

process fallbackについては、**process観測だけでは`Working`と`Idle`を区別できない**ことがGate 3で実測された。fallbackは推測せず`Unknown`を返す(§12.3)。

### 12.7 概要・pane状態・タスク完了の分離 — 確定(2026-09-07)

- paneの目的と現在地は短い概要として保持する。任意のハーネス連携から取得でき、連携なしでは
  手入力でも利用できる。自動要約は必須にしない。未取得の現在地やphaseをTerminalが推測しない。
- paneの状態観測と、ハーネスによるタスク完了は別の情報として扱う。既存AgentStateの語彙を
  そのままタスク完了判定に流用しない。メインpaneの応答終了やprocess終了だけで完了扱いにしない。
- タスク完了通知は、そのタスクに関連付けられたハーネスの明示信号を根拠とする。
  連携が無いときも通常Terminalと状態観測は利用できるが、タスク完了を推測して通知しない。
- メインpaneはタスクへの対応先として識別できるようにする。位置や最終選択paneから自動決定しない。
  別paneの判断待ちをメインpaneの状態で隠さない。
- メインpaneの登録は、**worktreeごとに1つ、ユーザーが明示的に選ぶ**。paneへの送信を伴う操作
  (§9.2のコメント送信等)が未登録のworktreeで起きたときは、その場で候補paneを提示して選ばせ、
  選ばれたpaneをそのworktreeのメインpaneとして記憶する。以後は既定の送信先として使い、
  ユーザーはいつでも選び直せる。初回に選ばれるまでは送信操作を無効にし、候補が1つでも自動では選ばない。
- 連携形式、セッションの識別と寿命、手入力と連携の優先順位、再実行時の完了解除、古いイベントの
  排除方法は未確定。Terminal専用APIをハーネス実行の必須条件にしない(§32)。

### 12.8 trust promptとPermission信号 — 確定(2026-09-08)

Claude Code／Codexの初回起動時のtrust prompt(作業ディレクトリを信頼するかを尋ねる画面)は
**Permission信号に含める。** タブ優先度では他のPermissionと同様に`Needs Attention`として扱う(§12.2)。

信号としての採用は§12.5の基準に従う。§12.5は採点済みでない信号の使用を認めないため、両CLIの
現行版で該当画面をfixture化し、Gate 3の検出率記録を再採点してから採用する必要がある。この作業自体は
Issue #252で行う。

## 13. 全Agent pane Overview

**確定(2026-09-07)。** 全Project／Task／Agent paneの概要と状態を一覧表示し、
Terminalとは独立したウィンドウで常時確認できる。従来の「一時的なOverviewに限定する」制約を撤回する。
操作の中心はAgent Terminalのままとし、一覧はその選択と状況把握を担当する。
Project RootのAgent paneも別枠で含める。タスクを切り替えずに各paneを閲覧できることを要求する。

表示例:

```text
Project A
  ログイン不具合修正
    ? メイン    ログイン不具合を修正する｜設計相談中
    ● 調査      認証エラーの発生条件を調べる
  検索機能追加
    ● メイン    検索機能を追加する｜実装中
    ○ レビュー  検索APIの設計を確認する｜応答終了
```

paneを選択すると対象worktreeと該当paneへ直接移動する。質問回答、Agent停止、Close、PR操作などは
Overviewから行わない。概要の入力UIの配置は未確定。状態はアイコンで示し、色だけに依存せず
accessibility labelで意味を伝える。paneの応答終了とタスク完了は別表示にする。

並び順は次のとおり。

1. 人間の対応が必要な状態
2. それ以外を最終操作順

`Question`、`Permission`、`Error`間に固定優先順位は付けず、最終更新順とする。

## 14. Evidence

### 14.1 責務分担

| 領域 | Agent／外部ツール | Terminal |
|---|---|---|
| スクリーンショット撮影 | 担当 | 担当しない |
| 撮影タイミング決定 | 担当 | 担当しない |
| PRへ掲載するEvidenceの選択 | 担当 | 担当しない |
| Evidence検出・取り込み | 登録可能 | 担当 |
| 表示、注釈、検索、保存 | 利用可能 | 担当 |
| Agentへのフィードバック | 受信 | 送信UIを提供 |

### 14.2 Evidence形式

v1の対象はスクリーンショットとメタ情報に限定する。

メタ情報の例:

- URL
- viewport
- browser
- 撮影時刻
- Project／worktree
- 任意の説明

画面録画、テスト結果、performance reportなどへの一般化は未確定であり、v1対象外とする。

### 14.3 注釈

PC、iPad、iPhoneで次の注釈を付けられる。

- ピン
- 矩形範囲
- コメント

フリーハンド描画は対象外とする。

注釈は元画像を破壊せず、別データとして保持する。座標は表示サイズに依存しない正規化座標で保持する案が示されている。具体的schemaは未確定。

画像、注釈座標、コメントをAgentへ送って修正依頼できる。

### 14.4 取り込み

次の2経路に対応する。

1. 特定ディレクトリのファイル監視
2. 登録API

v1はファイル監視から開始してよい。登録APIを必須にせず、Agent SkillとTerminalを密結合しない。

### 14.5 保存

```text
Agent creates evidence in worktree
        ↓
Terminal detects/registers it
        ↓
Terminal-managed project storageへ取り込む
        ↓
MetadataをDBへ保存
        ↓
Worktree削除後も保持
```

画像本体をSQLiteへ入れず、filesystemへ保存し、DBにはpathとmetadataを保存する構成が現在の推奨である。

## 15. Storage管理

### 15.1 管理対象

Storage画面を一本化し、Projectおよびデータ種別ごとの使用容量を確認できる。

- Evidence
- Diff Review snapshots／comments
- Consultation Logs／code snapshots
- その他のTerminal履歴

### 15.2 Cleanup

少なくとも次の単位で削除できる。

- Evidence単体
- worktree単位
- Project単位
- データ種別単位
- 古いEvidenceの一括削除

### 15.3 soft limit

- 容量上限は設定可能にする。
- 上限は保存を停止するhard limitではなく、cleanupを促すsoft limitとする。
- 超過しても新しいEvidenceを保存し続ける。
- 古いデータを削除候補として表示する。
- ユーザーの明示操作なしにEvidenceを自動削除しない。

Project別上限と全体上限のどちらを必須にするか、保存期間ベースcleanupを追加するか、初期上限値はいくつかは未確定。

## 16. Project登録、clone、Git認証

### 16.1 Project登録経路

次の2経路に限定する。

#### 既存Local Repository

1. ローカルディレクトリを選択
2. Git repositoryであることを検証
3. repository rootを抽出
4. Project Rootとして登録

#### Clone Repository

1. repository URLを入力
2. clone先のローカルディレクトリを指定
3. `git clone`を実行
4. cloneされたrepository rootをProject Rootとして登録

親ディレクトリ監視によるProject自動登録／discoveryは行わない。これはworktree自動検出とは別である。

### 16.2 Git認証

- 認証はOS、Git、SSH agent、Git Credential Manager等の既存環境へ完全委譲する。
- Terminal自身はtoken、password、SSH private keyを保存・管理しない。
- clone失敗時はGitのエラー出力をそのまま表示する。
- 専用の認証診断UIやトラブルシューティングシステムは作らない。
- 必要なら通常Terminalから原因を調査する。

## 17. Git操作方針

### 17.1 強くする閲覧機能

- status
- Commit／Base／Branch Diff
- worktree全体のシンプルなCommit Log
- commit選択からCommit Diff
- ファイル履歴
- blame
- branch、ahead／behind、未commit等の状態表示

### 17.2 GUI化しない変更操作

- commit
- push／pull
- stage／partial commit
- merge／rebase
- cherry-pick
- stash
- reset
- branch作成／削除

これらはAgentまたは通常Terminalから実行する。Project Rootからworktreeへの設定同期も同様である。

branch削除の唯一の例外がworktree Closeの後始末であり、**マージ済みbranchに限って**Closeの選択肢に含める(§3.4)。任意のbranchを選んで消せるUIは持たない。

Git graphは提供せず、シンプルなCommit Logに留める。

### 17.3 サポートするgit版数

サポート下限は**git 2.39**とする。2.39以上であれば機能制限を設けない。

Terminalはユーザーの`~/.gitconfig`に依存しない決定的な出力を得るため、各git読み取りコマンドへ形式固定用のoptionを明示する。この結果、実装上の実効下限は`git status --renames`の初出である2.18(2018-06)まで下がるが、**実行hostがMac/PCに限られる(§20.1)以上、そこまで下げる意味は無い**。macOS Command Line Toolsが配布するgitは2.39以降であり、下限を2.39に置いても現実の対象環境を落とさず、将来optionを追加する余地も残る。

下限未満を検出した場合は**警告を出すのみ**とし、動作の制限や接続の拒否は行わない(§4.3のtmuxと同じ方針)。版数を解釈できなかった場合は`Unknown`として保持し、「サポート対象」にも「対象外」にも丸めない(§12.3と同じ方針)。

ただしこの「警告のみ」は**Terminal側が能動的に拒否しないという意味であり、下限未満での動作を保証するものではない**。2.18未満では`status --renames`がoption解釈エラー(exit 129)となり、statusは部分的にではなく丸ごと失敗する。

## 18. Web／GUI確認

### 18.1 最終決定

- アプリ内Web Previewは実装しない。
- 通常URLも`localhost`も、すべてOSの外部ブラウザで開く。
- GUI確認はMac/PC上の外部ブラウザをAgentが操作して行う。
- Terminalアプリはbrowser、DevTools、DOM Inspector、Console、Network panelを再実装しない。
- PC画面をモバイルから操作するVNC機能は持たない。
- GUI確認結果はEvidence screenshotとしてモバイルから閲覧・注釈できる。

途中で検討されたDrawer内Web Preview案は撤回済みである。

## 19. 状態復元

### 19.1 復元単位

アプリ起動時、デバイスごとに次の状態を可能な範囲で復元する。

- Project
- worktree
- tmux session
- 選択pane
- Viewer Drawerの開閉
- Drawerの幅
- Viewerの左右／上下分割
- 開いていたCode／Diff／Evidence
- Diff review途中のsnapshot

PC、iPad、iPhoneの表示状態は完全に独立して保存する。PCで最後に見ていた位置をiPhoneへ同期しない。

### 19.2 復元前の再検証

前回位置をそのまま信用せず、起動時にProject／worktree／tmuxの現在状態を再取得する。

```text
Load device-local last location
        ↓
Refresh current project/worktree/session state
        ↓
Is previous worktree still Active and usable?
  ├─ Yes → restore
  └─ No  → do not restore silently
             ↓
          show candidates in same Project
```

前回worktreeがInactive、削除済み、または利用不能なら、別Projectへ勝手に移動しない。同じProject内のActive worktreeとMainを候補として表示する。

候補は、人間対応が必要なAgent状態を最優先し、その後を最終操作順に並べる。

対象tmux sessionだけが消えている場合は、Project／worktree画面へfallbackする。sessionを自動再作成するかは未確定。

## 20. Mac hostとiPhone/iPad architecture

### 20.1 確定した配置

```text
Mac / PC Host
├─ Git repositories and worktrees
├─ tmux sessions
├─ Claude Code / Codex / shell
├─ Docker / local DB / dev servers
├─ external browser and GUI verification
├─ Terminal Host Core
└─ local persistent storage
        ▲
        │ remote connection
        ▼
iPhone / iPad
├─ Project / worktree navigation
├─ Agent states and notifications
├─ Question handling
├─ Code / Diff / Evidence
└─ Terminal view connected to the host
```

- 実行環境はMac/PC hostだけに置く。
- Mobile端末にGit repositoryやAgent processを複製しない。
- GUI動作確認をローカル環境で行うため、現時点ではクラウドではなくMac/PCを母艦とする。
- iPhone/iPadは監視、レビュー、質問対応を主用途とし、必要なときに完全なTerminal操作へ入る。
- 外出先からの到達性はTailscale等の既存VPN／private networkへ委譲する。アプリはSSH接続のみを担当し、独自のリレーやNAT越え機能を持たない。
- Agent状態・Diff・Evidence等の構造化データをモバイルから取得できるのは、Mac側アプリ(Host Core)の起動中のみとする。アプリ非起動時もtmux sessionとAgentは動作し続け、素のSSH + tmux attachは可能である。
- **tmuxコマンドを実行するのはMac/PC host上のプロセスだけである。** tmuxコマンドの組み立て(引数の構築と検証)と、その実行(hostローカルのprocess起動／SSH越しの実行)を分離し、実行ファイルの解決を伴うローカル実行の型はhost platformに限定する。ローカル実行できない環境へ、必ず失敗するAPIを公開しない。
- **iPhone/iPadのTerminal描画方式は、macOS版と共通であることを要求しない。** macOS版でlibghostty(完全版)を採用する場合でも、モバイル側は実現可能なrendererを独立に選定してよい。モバイル側の具体的なrenderer選定は未確定(§21.5、§25)。

Swift／SwiftUI推奨構成を採る場合、実装上のhost対象はまずMacとなる。他OSのPC host対応は未確定。

### 20.2 Mobile Terminal UX

- 最終形は専用アプリ内Terminalとする。
- 同じtmux session、同じAgent TUIをそのまま表示する。
- Claude出力を解析した独自Chat UIには変換しない。
- Agent専用操作ボタンではなく、汎用Terminal補助キーバーを持つ。

補助キーバー例:

```text
[Esc] [Ctrl] [Alt] [Tab] [↑] [↓] [←] [→] [...]
```

外付けキーボードも通常どおり利用可能にする。

### 20.3 移行段階

**導入順序は通知を先、遠隔操作を後とする(確定、2026-09-07)。** 最初に§11.2のロック中の
判断待ち・タスク完了通知を実機で成立させ、その後に通知から対象へ戻る導線、プロンプト送信、
新規タスク開始を検証する。SSH Terminalや全構造化データprotocolの完成を通知の前提にはしない。

- 初期段階ではBlink等の外部TerminalからSSHまたはMoshでhostへ接続し、tmuxへattachする構成を利用できる。
- 最終構成は専用iOS/iPadOSアプリ内でSSH接続し、tmuxへattachする。
- Moshは外部アプリとして使うことは許容するが、プロダクト本体へは組み込まない。

## 21. 現在の推奨技術アーキテクチャ

> この章は**確定仕様ではなく、PoC通過を条件とする現在の第一候補**である。ただし章内で明示的に**確定**と記した項目(§21.5のrenderer方針)は除く。

### 21.1 推奨構成

| 領域 | 現在の推奨 |
|---|---|
| 言語 | Swift 6 |
| UI | SwiftUI + 必要最小限のAppKit／UIKit |
| Terminal core (macOS) | libghostty C API(完全版)。採用は**確定**(Gate 1通過、§21.5) |
| Terminal core (iOS/iPadOS) | 未確定。libghostty(完全版)への依存は要求しない(制約自体は**確定**、§21.5) |
| Terminal abstraction | `TerminalRenderer` protocolでrenderer依存を隔離し、platformごとに実装を差し替える |
| Multiplexer | tmux CLIを外部processとして操作 |
| Git | git CLIを外部processとして操作 |
| Remote terminal | SSH |
| iOS SSH | SwiftNIO SSH |
| Local DB | SQLite + GRDB.swift |
| Large binary storage | filesystem |
| Search | ripgrep CLI |
| Code Viewer | TextKit／SwiftUIベースのread-only viewer |
| Syntax highlighting (macOS) | HighlighterSwift（MIT。同梱するhighlight.jsはBSD-3）。採用は**確定**。JavaScriptCoreで動くため、上限を超える本文はハイライトせず素で表示する |
| Syntax highlight | v1は軽量実装。必要なら後でTree-sitter |
| Mobile data access | SSH上の別channelでHost Core CLIを呼ぶ案 |

### 21.2 推奨全体図

```text
                         Mac Host
┌────────────────────────────────────────────────────────┐
│ Swift 6 / SwiftUI App                                  │
│                                                        │
│ ┌──────────────────┐  ┌──────────────────────────────┐ │
│ │ TerminalRenderer │  │ Viewer Drawer                │ │
│ │ └─ libghostty    │  │ Code / Diff / Evidence      │ │
│ └────────┬─────────┘  └──────────────────────────────┘ │
│          │ PTY                                           │
│          ▼                                               │
│        tmux CLI                                          │
│          │                                               │
│   Agent / shell / test                                   │
│                                                        │
│ Host Core                                              │
│ ├─ Project / Worktree manager                          │
│ ├─ TmuxAdapter                                         │
│ ├─ AgentAdapters                                       │
│ ├─ Git reader                                          │
│ ├─ File watcher                                        │
│ ├─ Evidence manager                                    │
│ ├─ Search adapter                                      │
│ └─ SQLite + GRDB / filesystem                          │
└───────────────────────────┬────────────────────────────┘
                            │ SSH
                            ▼
┌────────────────────────────────────────────────────────┐
│ iPhone / iPad SwiftUI App                              │
│ ├─ TerminalRenderer (mobile, TBD; not libghostty)      │
│ ├─ SwiftNIO SSH                                        │
│ ├─ Code / Diff / Evidence UI                           │
│ └─ device-local UI state                               │
└────────────────────────────────────────────────────────┘
```

図中のlibghostty(完全版)はMac Host側のみに置く。iPhone/iPad側の`TerminalRenderer`実装は未確定であり、macOS版と同一である必要はない(§21.5)。

### 21.3 tmuxとgitをCLIで扱う理由

- source codeをアプリへコピーしない。
- ユーザーがTerminalで使う実体と、アプリが観測する実体を一致させる。
- tmux／gitのversion差をAdapter境界で吸収できる。
- libgit2等との挙動差を避ける。
- ライセンスおよび更新責任の境界を明確にする。

### 21.4 SSH channel分離案

Terminal画面と構造化データを同じ文字列streamから無理に抽出しない。

```text
One SSH connection
├─ Channel 1: tmux attach
├─ Channel 2: hostctl stream         # Agent/Git/state events
├─ Channel 3: hostctl diff ...
└─ Channel 4: hostctl evidence ...
```

`hostctl`はJSON Lines等を返す小さな内部CLIとし、SSHが認証、暗号化、host verificationを担当する案である。

この構成は現在の推奨案であり、`hostctl`のprotocol、versioning、権限、再接続は未確定。

### 21.5 libghostty隔離とplatformごとのrenderer

**確定**: macOS版の`TerminalRenderer`にlibghostty(完全版)を採用する。

**確定**: libghostty(完全版)の採用対象はmacOS版のみとする。iPhone/iPadのTerminal rendererはmacOS版と共通であることを要求せず、実現可能なものを採用する。

根拠: 2026-08-31時点の調査で、ghostty upstreamはv1.3.1以降、iOSを完全版ビルド(GhosttyKit)の対象から除外している。iOS向けに提供されるのはVTパーサのみを含む`libghostty-vt`であり、描画層は含まれない。macOS版の採用はGate 1の通過(2026-08-31、§24)を根拠とする。

アプリ全体をlibghostty APIへ直接依存させず、`TerminalRenderer` protocolでrendererを隔離する方針は維持する。

**確定**: surface内のプロセスが終了したあとsurfaceを作り直すかどうかは、**上位レイヤが決める**。`TerminalRenderer`は終了を状態(`exited`)として公開し`restart`を提供するだけで、自動では作り直さない。

根拠: libghostty v1.3.1には同じsurfaceでコマンドを再実行するAPIが無く、再接続はsurfaceを破棄して作り直すしかない(Gate 1申し送り#6)。一方、detachによる終了とユーザーが意図した終了をrendererは区別できない。自動で作り直すと、意図して終えたsessionを復活させてしまう。tmux sessionの存否を見て自動再attachするかどうかの判断は上位レイヤ(§3のworktreeライフサイクル)に属する。

**確定**: surfaceの**生成失敗**は異常系ではなく、遅延生成とリトライで扱う。リトライはrenderer実装体の内部責務とし、上位レイヤへ漏らさない。

根拠: ディスプレイスリープ中は`ghostty_surface_new`自体が失敗する(Gate 1申し送り#7)。これは「フタを閉じたままエージェントを走らせ続ける」という§4.2の想定運用で正常に起きる。ディスプレイの電源状態は上位レイヤの関心事ではなく、`start`の成功／失敗としても表現できない。リトライ回数に上限は設けない。

```text
TerminalRenderer
├─ GhosttyRenderer            # macOS、確定(Gate 1通過)
└─ MobileRenderer             # iOS/iPadOS、未確定
```

libghosttyの配布方法と固定versionの方針は**未確定**(§25)。Gate 1のスパイクはタグ`v1.3.1`にピン留めして実施したが、この版数固定を製品としての方針にするか、upstream追随に切り替えるかは決めていない。

モバイル側rendererの**候補**(列挙のみ。選定は未確定、§25):

| 候補 | 概要 | 補足 |
|---|---|---|
| `libghostty-vt` + 自前描画層 | iOSで利用可能なVTパーサの上に描画・入力を自前実装 | 描画・IME・selectionをすべて自作する負荷が大きい |
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)等の既存Swift renderer | permissive licenseの既存端末エミュレータを利用 | SwiftTermは2026-08-31時点でMIT(GitHub license metadataで確認)。採用時は固定versionで再監査する |
| 外部SSHアプリ連携 | 当面はBlink等の外部Terminalへ委譲(§20.3) | 専用アプリ内Terminalの最終形とは別の段階的手段 |

### 21.6 採用しない／後回しの候補

| 候補 | 状態 | 理由 |
|---|---|---|
| iOSでの完全版libghostty(GhosttyKit) | 対象外 | upstreamがv1.3.1以降、iOSを完全版ビルドの対象から除外(2026-08-31確認)。iOS向けは`libghostty-vt`のみ提供される |
| Rust Core + Swift UI | 次点、未採用 | Swift + Rust + libghostty側Zig/Cの多言語構成が初期段階では過剰 |
| Tauri + xterm.js | 未採用 | UI開発は速いが、最重要のTerminal品質目標で第一候補に劣る可能性 |
| libgit2 | v1不採用 | 実Gitとの挙動差と依存増を避ける |
| 独自Remote Terminal protocol | 不採用 | SSH + tmuxで代替できる |
| Mosh組み込み | 回避 | copyleft／App Store配布上の検討をプロジェクトへ持ち込まない |
| Tree-sitter | v1不採用 | read-only Code Viewerに対して初期スコープが大きい。言語ごとにC依存を個別に足すことになり、§7.3の「v1でEditor engineを作らない」に対して過剰 |
| 独立Host Core daemon(launchd常駐) | 不採用 | Host Coreはアプリプロセス内に置く。構造化データ提供はアプリ起動中のみで十分とし、プロセス間通信の複雑さを避ける |

## 22. Local data architecture

### 22.1 現在の推奨データ配置

```text
Application Support/
└─ <app>/
   ├─ app.sqlite
   └─ projects/
      └─ <project-id>/
         ├─ evidence/
         └─ snapshots/
            ├─ diff-reviews/
            └─ consultations/
```

SQLite候補テーブル:

- `projects`
- `worktrees`
- `tmux_sessions`
- `device_ui_states`
- `consultations`
- `diff_reviews`
- `review_comments`
- `evidence_metadata`
- `evidence_annotations`
- `agent_events`
- `settings`

これは論理候補であり、schema、migration、ID、foreign key、retentionは未確定。

SQLite + GRDBが正式採用になるまでの間、§3.2.1のworktree Active/Inactiveのように再起動を跨いで
復元する必要がある状態は、Application Support配下のJSONファイルへ暫定的に保存する。GRDB採用時に
移行する前提の暫定措置であり、この暫定保存をもってschemaやmigrationの方針を決めたことにはしない。

なお`device_ui_states`はhost Mac自身のUI stateを保存する用途とする。iPhone/iPadのUI stateは§19の端末独立原則に従い各デバイスのローカル保存とし、host DBへは同期しない。

### 22.2 保存原則

- 画像本体や大きなsnapshotはfilesystemへ置く。
- SQLiteにはmetadata、path、関連ID、状態を保存する。
- device UI stateは端末ごとに分離する。
- Project／worktreeの外部実体をDBだけで信用せず、起動時に再検証する。
- worktree削除とTerminal履歴削除を連動させない。

## 23. OSS／ライセンス方針

> この節は法的助言ではない。実際の配布前に、採用する固定versionと全transitive dependencyを再確認する。

### 23.1 現在の推奨ポリシー

- MIT、BSD、ISC、Apache-2.0等のpermissive licenseを原則許可する。
- GPL、LGPL、AGPL、unknown licenseは原則不採用とし、例外承認制にする。
- 依存追加時とCIでlicense scanを実施する。
- source、binary、font、icon、grammar、sample assetを別々に監査する。
- license text、copyright notice、NOTICE等の配布要件をThird-Party Noticesへ反映する。
- 依存versionを固定し、releaseごとにSBOM／license reportを生成する。
- 既存プロジェクトのコードを「参考」と称してコピーしない。必要な場合は正規dependencyとして利用するか、clean-roomで実装する。

このポリシー自体は会話で推奨されたものであり、プロジェクトの正式採用決定は未確定である。

ただし**本体のlicenseはMITで確定**とする(repositoryの`LICENSE`ファイルと一致)。

### 23.2 主要候補の確認結果

| Component | 2026-08-31時点で確認したlicense | 方針 |
|---|---|---|
| [Ghostty / libghostty](https://github.com/ghostty-org/ghostty/blob/main/LICENSE) | MIT | macOS版で採用(確定、§21.5)。iOSの完全版は対象外。固定commit／配布物の依存も再監査 |
| [libghostty-vt](https://github.com/ghostty-org/ghostty/blob/main/LICENSE) | MIT(Ghostty本体と同一repository) | モバイルrenderer候補の一つ。VTパーサのみで描画層を含まない |
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm/blob/main/LICENSE) | MIT | モバイルrenderer候補の一つ。採用時は固定versionで再確認 |
| [tmux](https://github.com/tmux/tmux) | ISC | source組込みではなく外部CLIとして利用 |
| [SwiftNIO SSH](https://github.com/apple/swift-nio-ssh) | Apache-2.0 | iOS SSH候補 |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | MIT | SQLite access候補 |
| [ripgrep](https://github.com/BurntSushi/ripgrep/blob/master/FAQ.md#how-is-ripgrep-licensed) | MIT または Unlicense | 外部CLI候補。プロジェクトではMIT条件を採用する案 |
| [Tree-sitter core](https://github.com/tree-sitter/tree-sitter/blob/master/LICENSE) | MIT | 将来候補。各言語grammarは個別確認 |
| [Mosh](https://github.com/mobile-shell/mosh) | GPL-3.0系。iOS向け追加文書あり | アプリへの組込みを避け、必要なら外部アプリとして利用 |

### 23.3 branding

コードのlicenseと、名称・ロゴ・アイコンの利用可否は別問題として扱う。

- 独自プロダクト名を使う。
- 独自アイコンを作る。
- `Ghostty Mobile`等、公式派生に見える名称を避ける。
- Ghostty公式アイコンやブランド資産を流用しない。
- 必要な場合はAbout／Third-Party Noticesで「Terminal rendering powered by libghostty」等の正確なクレジットを行う。

プロダクト名は未決定であり、採用前にGitHub、Homebrew、App Store、商標、ドメイン等の名称衝突を別途確認する。

## 24. PoC優先項目

### Gate 1: macOS Terminal品質 — 最優先

**状態: 通過(2026-08-31)。** この結果を根拠に、macOS版rendererへのlibghostty採用を確定とした(§21.5)。

`SwiftUI + libghostty + PTY + tmux attach`で、実際のClaude Code／Codex／shellを動かす。

確認事項:

- VT互換性
- Metal描画とresize
- IME、日本語入力、絵文字、grapheme width
- copy／paste、selection、URL／path hit testing
- mouse protocol
- tmux split／zoom／attach／detach
- 大量output、長時間稼働、memory
- AppKit bridgeが必要な範囲

検証の証跡(実測値、スクリーンショット、再現手順)と、撤退基準への当てはめ、本体実装への申し送り15項目は`Spikes/gate1/README.md`の判定サマリにまとめてある。自動検証で残った項目(実IMEでのかな漢字変換、物理キーボード／マウス／トラックパッド、描画品質・体感遅延)は2026-08-31に手動で確認し、問題なしとした。

以下は本Gateでは検証しきれておらず、**本実装後に計測**する。

- 数時間〜数日規模の長時間稼働(スパイクでの実測は35分ソークまで)
- 複数surface(5〜10)同時のメモリ／CPUと`ghostty_surface_free`のリーク
- 外部ディスプレイ間の移動、scale factor変化、スリープ／復帰
- `vttest`相当の網羅的なVT検証

### Gate 2: iPad/iPhone Terminal

`SwiftNIO SSH → tmux attach → 選定したmobile renderer描画`を実機で確認する。

前提: モバイル側rendererはmacOS版と共通である必要がない(**確定**、§21.5)。libghostty(完全版)はiOS対象外のため、Gate 2はrenderer候補の比較から始める。

確認事項:

- mobile renderer候補の比較(`libghostty-vt` + 自前描画／SwiftTerm等の既存renderer／外部SSHアプリ連携)
- 選定rendererのVT互換性、日本語・絵文字のgrapheme width、selection
- host key verification
- password／public key／SSH agent相当の認証方式
- connection lossと再接続
- app background／foreground
- software keyboard、IME、補助キーバー
- iPhoneの狭い幅でAgent TUIが実用になるか
- iPad multi-window／external keyboard
- 同一tmux sessionへのMac＋mobile同時attach

### Gate 3: Agent Adapter

**実施済み(2026-09-03)。** 計画は`Spikes/gate3/PLAN.md`、実測記録と未計測項目は`Spikes/gate3/README.md`。この結果を根拠にAdapter API形状を確定した(§12.4)。**Gate 3の成立／不成立の判断そのものは行っていない** — 取得できない状態は`Unknown`として明示する方針が既に確定しているため(§12.3、下記「PoC後の判断」)、本Gateの産物は可否ではなくどこまで縮退するかの境界線である。

Claude CodeとCodexについて、共通状態をどこまで正確に取得できるか検証する。

確認事項:

- Working
- Question
- Permission
- Completed／Ready for Review
- Error
- Idle
- Unknown
- pane／processとの安定した紐付け
- version update耐性
- fallback時の誤判定

### Gate 4: Host Core over SSH

別SSH channelでAgent状態、Git状態、Diff、Evidence metadataを安全に取得できるか検証する。

確認事項:

- JSON Lines framing
- reconnectとcursor
- protocol versioning
- large Diff／image transfer
- command injection防止
- path traversal防止
- project access boundary

### Gate 5: snapshotと復元

- Diffを固定したまま背後のファイルが変更されるケース
- Refreshで新snapshotを作成し、旧コメントを保持できること
- worktree／tmux消失後の安全な復元fallback
- device別Drawer状態の復元
- worktree削除後のConsultation／Evidence参照

### PoC後の判断

Gate 1は通過済みであり、macOS版のTerminal renderer候補を再評価する必要はない(§21.5で確定)。Gate 2が不成立でも、macOS版を先行し、モバイルは外部SSH／Moshアプリ連携で段階提供できる。Gate 3で取得できない状態は推測で埋めず、`Unknown`として明示する。

## 25. Terminal本体の未確定事項一覧

### Product／scope

- プロダクト名
- 対応OSの初期version
- Mac専用から他PC hostへ広げるか
- v1、v2の正式な機能境界

### UI

- Project／Task Tab／Overviewの詳細レイアウト
- 状態アイコン、色、accessibility label
- Drawerの初期幅、最大幅、split比率
- iPhone上のAgent TUI縮小戦略
- keyboard shortcut体系
- Overview以外のmulti-window対応(Diffは別窓を要求し、組み込み／外部連携の選択は未確定)

### Worktree／tmux

- tmux未導入時のセットアップ
- session消失時の再作成方針
- detach時にrenderer surfaceのプロセスが終了する挙動を踏まえた、**タブ**のライフサイクル設計(Gate 1)。surface側の責務分担は§21.5で確定済みで、残るのは「上位レイヤがどう再生成を判断するか」(tmux sessionの存否確認、タブを閉じる条件)

### Agent

- 各Adapterが採用するsignalの組み合わせ(個々の信号の採用基準は§12.5で確定。どう合成して7状態へ落とすかは実装時に決める)
- false positive／false negativeの許容条件(振動の可否とターン開始直後のfalse positiveは§12.2で決着済み)
- 質問fallbackのデータ交換形式
- `Ask Agent`実行時に使用するAgent CLIの選択方法
- Unknown通知のデフォルト時間
- 概要連携のschema、セッション識別と寿命、手入力との優先順位
- タスク完了信号の関連付け、再実行時の解除、古い／重複イベントの排除
- 通知の重複抑止、再接続時の再通知、消失したpaneへの通知導線

### Git／Diff

- rename、binary Diff、submodule、LFS
- 競合(unmerged)ファイルの差分本文(combined diff)の表示方法

### Mobile／remote

- モバイル側Terminal rendererの選定(`libghostty-vt` + 自前描画／SwiftTerm等の既存renderer／外部SSHアプリ連携)
- iOS認証情報の安全な保存方法
- SSH接続設定の同期範囲
- Push通知中継の具体的な実装・提供形態(自前hosting等)
- Host発見、pairing、複数Host
- 推奨するVPN構成の具体例とドキュメント化
- Host Core CLI protocol

### Storage

- DB schemaとmigration
- Application Support上の正式path
- encryption at restの要否
- soft limitの初期値と適用単位
- cleanup候補の選び方
- backup／export／import

### OSS

- Contributor License Agreement／DCOの要否
- license scan tool
- SBOM形式
- libghostty配布方法と固定version(Gate 1のスパイクはタグ`v1.3.1`にピン留めして実施。製品としてこの版数を固定するか、upstream追随に切り替えるかは未決定)
- Ghostty attribution文言
- App Store審査上の確認

---

# Part II. Agent Skills／AI開発フロー内部設計

## 26. Terminal本体との責務分離

Agent Skillsの内部設計は、Terminalアプリ本体の仕様とは別に管理する。

| 領域 | Agent Skills | Terminal本体 |
|---|---|---|
| Project規則に従うworktree作成 | 担当 | 検出・表示・Active管理 |
| 要件対話 | 担当 | Terminal／質問UIを提供 |
| 詳細設計 | 担当 | 状態と成果物を表示 |
| 実装、test、commit | 担当 | Agent TerminalとGit閲覧を提供 |
| 検証、PR作成 | 担当 | Ready for Review／Diff／Evidenceを表示 |
| Evidence撮影 | 担当 | 取り込み・閲覧・注釈・保存 |
| 不足要件の質問生成 | 担当 | Agent-native UIを優先し、必要ならfallback表示 |
| phase orchestration | Agent Skills側 | 実装サイクル自体は管理しない |
| Agent状態の通知 | 任意のsignal提供 | Adapterで正規化して通知 |

Terminalは、Agent Skillsが存在しなくても通常Terminalおよびworktree managerとして動作できることを目標とする。

## 27. Agent開発フローで確認できた意図

次はユーザーから提示された方針であり、Agent Skills側の設計入力として扱う。

- 開発を要件定義、詳細設計、実装のphaseに分ける。
- 要件定義は人とAIの対話で進め、人がレビューする。
- 要件レビュー後は、可能な限りPR作成までノンストップで進める。
- phaseごとにAgent contextをclearする。
- phase間の引き継ぎはchat historyではなくfileで行う。
- worktreeの命名、配置、作成はProject rulesに従ってAgentが担当する。
- Agentが生成したEvidenceをPR作成時に利用できるようにする。

ただし、次章以降の詳細なphase構成、artifact名、state machineは参照会話で提案された設計案であり、ユーザーによる最終確定はしていない。

## 28. 現在のAgent Skills設計

### 28.1 phase構成 — 確定

```text
Requirement Session
  Human × AI
  ↓ requirements artifact
  Human approval
        ↓
Design Session (fresh context)
  ↓ design + task plan artifacts
  automatic design gate
        ↓
Implementation Session (fresh context)
  ↓ code + tests + commits
        ↓
Review Session (fresh context)
  ↓ requirement/design/diff verification
  ├─ NG → new Implementation Session
  └─ OK → PR creation
```

当初の3phaseに、実装とは別contextのReview／Verify sessionを追加した**4phase構成を最終目標として確定**とする。各phaseの入力・出力・終了条件などの詳細は未確定である(§31)。

### 28.2 context isolation案

- Requirement、Design、Implementation、Reviewはそれぞれfresh sessionを使う。
- 却下案や試行錯誤を次phaseのcontextへ暗黙継承しない。
- 引き継ぐ情報は明示したartifact fileに限定する。
- Review NG後も以前のImplementation sessionをresumeせず、新しいsessionへreview artifactを渡す案とする。

### 28.3 Human interrupt案

「ノンストップ」と「Agentが不足要件を勝手に決める」を分離する。

- 設計裁量内の判断はAgentが続行する。
- product behaviorや受け入れ条件を変える要件不足はHumanへ質問する。
- Human回答が必要なときだけ処理を中断する。

何を設計判断とし、何を要件判断とするかの境界は未確定である。

## 29. Artifact案 — 未確定

会話では次の固定artifact案が提示された。

```text
.ai/
├─ requirements.md
├─ design.md
├─ task-plan.md
├─ status.json
└─ review.md
```

### requirements.md案

- Goal
- Requirements
- Acceptance Criteria
- Out of Scope
- 人が承認した結果

### design.md案

- Architecture
- Changes
- Decisions
- Risks

### task-plan.md案

- Implementation Agentが順に実行する作業項目
- designを再解釈するのではなく、設計をcodeへ変換するための計画

### review.md案

- Requirement coverage
- Design compliance
- Bug
- Security
- Test coverage
- Unnecessary changes
- 修正要求または承認

### status.json案

- 現在phase
- status
- block reason
- artifact versions
- next action

これらのfile名、schema、配置、Gitへcommitするか、更新責任、承認表現はすべて未確定である。

## 30. Agent state machine案 — 未確定

```text
DRAFT
  ↓
REQUIREMENT
  ↓
REQUIREMENT_REVIEW
  ├─ Reject → REQUIREMENT
  └─ Approve
       ↓
DESIGN
  ├─ requirement ambiguity → HUMAN_REQUIRED
  └─ design complete
       ↓
IMPLEMENT
  ├─ retryable failure → IMPLEMENT
  └─ implementation complete
       ↓
VERIFY
  ├─ reject → new IMPLEMENT session
  └─ approve
       ↓
PR_CREATING
  ↓
PR_READY
```

このstate machineはAgent Skills側の内部状態であり、Terminal共通Agent Stateと同一にしない。

対応関係の例:

| Agent Skills内部状態 | Terminal共通表示の候補 |
|---|---|
| REQUIREMENT／DESIGN／IMPLEMENT／VERIFY | Working |
| HUMAN_REQUIRED | Needs Attention / Question |
| retry不能error | Needs Attention / Error |
| PR_READY | Ready for Review |
| 判定不能 | Unknown |

このmappingもAgent Adapter実験後に確定する。

## 31. Agent Skills側の未確定事項

- 要件定義後のHuman reviewだけで十分とする条件
- 自動Design Gateの検査内容
- 不足要件と設計裁量の判定基準
- 各phaseの入力、出力、終了条件
- artifact file名とschema
- artifactをGit管理するか
- review NG時の最大loop回数
- retry不能時の停止条件
- Implementation Agentが設計不備を発見した場合の戻り先
- Review Agentの独立性と利用model
- PR作成条件
- Evidence撮影の必須条件
- Agent-native質問UIとfile-based質問の使い分け
- Terminalへの任意signal／registration API
- Claude CodeとCodexで共通Skillを使う方法

## 32. TerminalとAgent Skillsの統合原則

今後の設計では、次の原則を維持する。

1. Agent SkillsがTerminal専用APIなしでも実行できる。
2. TerminalはAgent Skills固有fileの存在を必須にしない。
3. より正確な状態が取得できる場合だけAdapterで拡張する。
4. 質問はAgent-native UIを優先し、file／API方式はfallbackまたは拡張とする。
5. worktree作成規則、設計判断、実装loopはAgent Skills側に置く。
6. TerminalはProject、worktree、tmux、状態、通知、閲覧、review snapshot、履歴、Evidenceを担当する。
7. Agent Skills内部状態が取れない場合、Terminalが推測でphaseを作らない。
8. Agent Skillsの実装サイクルとTerminalのDiff Review履歴を強制的に1:1対応させない。

---

# 付録A. 確定事項チェックリスト

- [x] 全Project／Task／Agent paneの短い概要と状態アイコンを独立Overviewウィンドウに表示
- [x] 概要は任意のハーネス連携と手入力に対応し、観測できない現在地を推測しない
- [x] paneの応答終了とハーネスによるタスク完了を区別し、完了通知は後者を根拠にする
- [x] Macアプリ起動を前提にiPhoneロック中の判断待ち・タスク完了通知をモバイル初版の利用条件とする
- [x] P2を維持し、モバイルは通知を先に、遠隔操作を後に導入する

- [x] 1 Task = 1 worktree = 1 Task Tab
- [x] Project Rootは別枠の常設tmux session
- [x] worktreeごとに独立tmux session
- [x] worktreeの安定IDは管理ディレクトリの絶対パス、tmux session名は安定IDだけから導出する`awt-<slug>-<安定IDのSHA-256先頭8桁>`
- [x] アプリはユーザーの既定tmuxサーバを使い、専用socketへ隔離しない
- [x] 観測中に新規出現したworktreeは自動Active化、初回スキャンで見つかったworktreeはInactiveから始める
- [x] Active/Inactiveは再起動を跨いで復元する。停止中に現れたworktreeはInactiveから始め、停止中に消えたworktreeは落とさず到達不能として保持する
- [x] GRDB正式採用までの再起動を跨ぐ状態はApplication Support配下のJSONへ暫定保存する(schema／migrationの決定とはしない)
- [x] 作業ツリーへ到達できないworktreeは`到達不能`として保持し、タブは残すがグレーアウトして選択不可。検出結果は消失と未観測を区別してActive/Inactiveを保つ
- [x] bare repositoryをProject Rootに持つレイアウトではProject Rootを持たない(`projectRoot == nil`を正常系として扱う)
- [x] Closeは4択(UIのみ／tmux session終了／worktree削除／マージ済みbranch削除)、削除系は未commit・未push・未mergeを検査して警告する
- [x] 未merge検査が使うProjectの既定branchは`origin/HEAD`、無ければmain worktreeのbranch。壊れた値ではフォールバックせず、特定できなければ判定不能として警告する
- [x] Close削除系の検査にignoredファイルの存在を含める。upstream設定はあるが追跡refが無い状態は未push／push済みと別の状態として扱う
- [x] 「マージ済み」の判定はancestor判定に加え、patch相当の同一性(squash merge)も検出する
- [x] HEADがbranchを指していない(detached HEAD)worktreeはCloseそのものを拒否する(既存の警告して続行可な検査より強い扱い)
- [x] worktree内はpane分割中心、tmux window追加を基本にしない
- [x] Agent Terminal中心
- [x] Viewer Drawerは最大2分割
- [x] Code／Diff／Evidenceを必要時だけ表示
- [x] Viewer DrawerはOverlayで閉じた場合だけ次回もOverlayで開き、Inline／Fullscreenで閉じた場合はInlineで開く
- [x] File Browserはignoredを含む全ファイル、lazy load
- [x] trackedファイルのGit状態はindex／worktreeの2軸を保持し、ディレクトリへ配下の状態を集約しない
- [x] 大容量ファイルのデフォルト閾値は1 MiB／50,000行、バイナリは先頭8 KiBのNULバイトで判定
- [x] `Open anyway`後も絶対上限（デフォルト16 MiB）までで打ち切り、打ち切りを表示する。バイナリは確認後も本文を出さない
- [x] worktree root直下の`.git`は列挙しない。サブモジュール配下はGit状態なし
- [x] Code Viewerはread-only、自動更新、history／blameあり
- [x] DiffはCommit／Base／Branchの3種
- [x] Diffはsnapshot、Refreshで新snapshot
- [x] Base branchはupstream→`origin/HEAD`の既定branch→ユーザー選択の順で決め、結果をタスクタブごとに記憶する
- [x] Base／Branch Diffのrangeはmerge-base起点 (base branchの進行分をレビュー範囲へ混ぜない)
- [x] Base／Branch Diffはworking tree・staged・untrackedを含め、出所を5種(競合(unmerged)を含む)で区別表示する (ignoredは含めない)。競合(unmerged)は一覧とDiffに表示するがコメント送信の対象外
- [x] コメントのanchorは`(snapshot ID, パス, old／new, 行範囲, 行テキストのハッシュ)`、新snapshotへの推測追従はしない
- [x] Diffコメントは単体／batchでAgentへ送信
- [x] Diffレビューコメントの送信は`Idle`と`Completed`のときだけ許可し、他状態(`Working`／`Question`／`Permission`／`Error`／`Unknown`)と状態エントリが無いpaneでは送信操作を無効化してコメントをUI側に保持する
- [x] GitHub PR review連携はしない
- [x] Consultationはfresh contextが基本、paneは再利用
- [x] Consultation LogはProject単位で永続化し、Gitには載せない
- [x] Agent-native質問UIを優先
- [x] 全worktree横断Questions Inboxは作らない
- [x] Mac／mobile通知とdeep link
- [x] Agent Adapterで複数Agentを抽象化
- [x] Unknownを正式状態として扱う
- [x] Adapterの状態取得はevent購読が基本形、pollingはAdapter内部の実装詳細
- [x] 生存確認と状態観測はAPIとして分ける(`Agentが居ない`は`Unknown`ではない)
- [x] 状態観測は種別不明でも大分類だけを伝えられる(AgentStateの7状態語彙は変えない)
- [x] `Unknown`の理由は列挙型で持ち、表示専用の文字列と分ける
- [x] Mac/PC host、iPhone/iPad client
- [x] 同一tmux sessionへ複数deviceからattach、入力排他なし
- [x] 複数device同時attach時の`window-size`は`smallest`、自分の作ったwindowごとに設定(`-g`は使わない)
- [x] tmuxのサポート下限は3.4、3.5未満はZWJ表示の警告のみで機能制限なし
- [x] gitのサポート下限は2.39、下限未満は警告のみで拒否しない
- [x] paneへのテキスト注入は`load-buffer` + `paste-buffer -p`、受け側次第で実行され得ることは残存リスクとして受容
- [x] `scrollback-limit` 10MBと`history-limit` 10000を製品既定として明示(tmux側はsession単位)
- [x] 代表状態はNeeds Attention／Ready for Reviewへ即時反映、`Idle`／`Unknown`へ入る遷移は遷移元を問わず9秒保持
- [x] Adapterが使う信号はGate 3の混同行列に数字が残るものに限る
- [x] Claude Code／Codexの初回起動時trust promptはPermission信号に含め、タブ優先度で`Needs Attention`として扱う(信号採用時のfixture化・再採点は§12.5に従う)
- [x] tmuxコマンドの組み立てと実行を分離し、ローカル実行の型はhost platformに限定
- [x] mobileは同じTerminal TUI + 汎用補助キーバー
- [x] macOS版の`TerminalRenderer`にlibghostty(完全版)を採用(PoC Gate 1通過、2026-08-31)
- [x] libghostty(完全版)の採用対象はmacOS版のみ、モバイルrendererはmacOSと共通であることを要求せず実現可能なものを採用
- [x] surfaceのプロセス終了後に作り直すかは上位レイヤが決める(rendererは状態と`restart`を公開するだけ、生成失敗のリトライはrenderer内部の責務)
- [x] Project登録はlocal選択またはclone
- [x] Git認証は既存環境へ完全委譲
- [x] Git GUIは閲覧中心
- [x] UI状態はdeviceごとに独立復元
- [x] Evidenceはscreenshot + metadata、pin／rectangle annotation
- [x] Evidence取り込みはfile watch + API
- [x] EvidenceはTerminal管理領域へ保存し、worktree削除後も保持
- [x] Storage画面を一本化
- [x] 容量上限は設定可能なsoft limit、自動削除なし
- [x] URLはlocalhostを含め外部browser
- [x] Web Preview／DevTools／VNCは作らない
- [x] 単一ユーザー前提(マルチユーザー／チーム共有は対象外)
- [x] 本体licenseはMIT
- [x] リモート到達性は既存VPNへ委譲、独自リレー／NAT越えは持たない
- [x] 構造化データ提供はMacアプリ(Host Core)起動中のみ、独立daemonは作らない
- [x] Push通知はopt-inの軽量中継 + 最小payload(コード・出力は載せない)
- [x] UI名称は`Ask Agent`(Agent非依存)
- [x] Diffコメントの送信先は実装Agent pane
- [x] コメントanchorは出所を含む6要素(snapshot ID／出所／パス／側／行範囲／テキストハッシュ)
- [x] メインpane(= 実装Agent pane)はworktreeごとにユーザーが明示選択して登録し、自動決定しない
- [x] Agent開発フローはReview独立sessionを含む4phase構成

# 付録B. 現在の推奨構成チェックリスト

- [ ] Swift 6／SwiftUIを正式採用 — PoC待ち
- [ ] libghosttyの配布方法と固定versionの方針を決定 — スパイクは`v1.3.1`ピン留め、製品方針は未確定(§25)
- [ ] モバイルTerminal rendererを選定 — 候補比較とGate 2 PoC待ち(§25)
- [ ] tmux CLI Adapterを正式採用 — version検証待ち
- [ ] git CLI Adapterを正式採用 — output parsing設計待ち
- [ ] SwiftNIO SSHを正式採用 — iOS実機PoC待ち
- [ ] SQLite + GRDBを正式採用 — schema設計待ち
- [ ] ripgrep CLIを正式採用 — bundle／host依存方針待ち
- [ ] hostctl over SSHを正式採用 — protocol PoC待ち
- [ ] permissive-only license policyを正式採用 — governance決定待ち

# 付録C. 参照先

- [Ghostty license](https://github.com/ghostty-org/ghostty/blob/main/LICENSE)
- [Ghostling: minimal libghostty C API example](https://github.com/ghostty-org/ghostling)
- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm/blob/main/LICENSE)
- [tmux](https://github.com/tmux/tmux)
- [SwiftNIO SSH](https://github.com/apple/swift-nio-ssh)
- [GRDB.swift](https://github.com/groue/GRDB.swift)
- [ripgrep licensing FAQ](https://github.com/BurntSushi/ripgrep/blob/master/FAQ.md#how-is-ripgrep-licensed)
- [Tree-sitter license](https://github.com/tree-sitter/tree-sitter/blob/master/LICENSE)
- [Mosh](https://github.com/mobile-shell/mosh)

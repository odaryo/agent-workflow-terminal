#!/usr/bin/env python3
"""PreToolUse (matcher: Bash) フックの判定本体。

stdin の hook JSON から tool_input.command を読み、tmux の破壊操作 (kill-se* で始まるトークン)
が隔離 socket を伴わないときに exit 2 で拒否する。exit 2 だけが tool 呼び出しを止める
(それ以外の終了コードは block しない) ため、判定できないときも exit 2 に倒す。
事故の経緯と設計は Issue #314 / CLAUDE.md「外部 CLI を計測するときの作法」。

逃し道は用意していない。既定 server への write が必要ならユーザーが Bash ツールの外で実行する
(コマンド文字列上のマーカー方式は、マーカーを足せば通ることをエージェントが学習して常用するため)。

字句解析は入力長に対して線形であること。bash 実装はここが二次で、10 秒の hook timeout を
超えたところでガードが黙って消えていた (実測 2026-09-09: 20KB で 3〜34 秒)。timeout は
ツール呼び出しを止めないため、それは拒否ですらなく素通りとして現れる。**部分文字列のコピーを
反復ごとに作らないこと** — 走査は必ずインデックスを進める形か re のスキャンで行う。

依存は標準ライブラリのみ。shlex は heredoc もリダイレクトも扱わないため使わない。
"""

import json
import os
import re
import sys

# 語の切り出しは「次の特殊文字までを 1 回のスライスで取る」。特殊文字ごとに 1 回だけ
# コピーが起きるので、走査全体は入力長に対して線形になる。
_SPECIAL_RE = re.compile(r"[ \t\n\\'\"$`;&|()<>#]")
_DQ_SPECIAL_RE = re.compile(r"[\\\"$`]")
_SQ_RE = re.compile(r"'")
_SUB_RE = re.compile(r"[\\$`]")
_PAREN_RE = re.compile(r"[()]")
_ASSIGN_RE = re.compile(r"^[A-Za-z_][A-Za-z_0-9]*=")

# 上限は「ここに来るのは kill-se を含む文字列だけ」という前提での安全弁。実測
# (2026-09-09、macOS / CPython 3.14、性能 fixture の 4 形) では 125,000 文字で 0.035 秒、
# 990,000 文字でも 0.18 秒であり、どの形でも長さにほぼ比例する。hook の timeout 10 秒に
# 対して 55 倍の余裕があるので上限で塞ぐ必要は無いが、想定外の形で超線形になったときに
# 「黙って timeout して素通り」ではなく拒否側へ倒すための backstop として残す。
# 単位は**文字数** (バイト数ではない)。日本語混じりだと UTF-8 バイト数はこの 2〜3 倍になる。
MAX_COMMAND_CHARS = 1_000_000

# コマンド置換の入れ子で解析対象が増えすぎたときも、黙って打ち切らず拒否に倒す。
MAX_QUEUED_STRINGS = 64

SHELL_COMMANDS = frozenset(("bash", "sh", "zsh", "dash", "ksh"))

KEYWORDS = frozenset((
    "{", "}", "!", "if", "then", "else", "elif", "fi", "while", "until",
    "for", "do", "done", "case", "esac", "select", "coproc",
))

PREFIX_COMMANDS = frozenset((
    "env", "timeout", "nohup", "nice", "stdbuf", "command", "exec", "time",
    "sudo", "xargs", "caffeinate", "builtin",
))

# 引数を組み立て直してシェルに再解釈させるもの。中身は 1 プロセスのコマンド文字列の中に
# あり、既に検査対象の中なので `bash -c` と同じく中身を検査へ回す。
EVAL_COMMANDS = frozenset(("eval",))

# 値を次の語で取るオプション
PREFIX_VALUE_OPTIONS = {
    "env": frozenset(("-u", "-C", "-S")),
    "timeout": frozenset(("-s", "-k")),
    "nice": frozenset(("-n",)),
    "stdbuf": frozenset(("-i", "-o", "-e")),
    "sudo": frozenset(("-u", "-g", "-p", "-C", "-r", "-t", "-U")),
    "xargs": frozenset(("-I", "-J", "-L", "-n", "-P", "-s")),
    "time": frozenset(("-o",)),
}

# 値を取らない / 値が連結されたオプション。ここに無い綴りは「解釈できなかった」として
# 通す方向へ倒さない (kill-se を含む場合は拒否になる)。
PREFIX_FLAG_OPTIONS = {
    "env": frozenset(("-i", "-0", "-v", "--ignore-environment", "--null", "--debug")),
    "timeout": frozenset(("-f", "-v", "--foreground", "--preserve-status", "--verbose")),
    "command": frozenset(("-p", "-v", "-V")),
    "exec": frozenset(("-a", "-c", "-l")),
    "xargs": frozenset(("-0", "-o", "-p", "-r", "-t", "-x")),
    "time": frozenset(("-p", "-l")),
}

PREFIX_FLAG_PREFIXES = {
    "env": ("--unset=", "--chdir=", "--split-string=", "-u", "-C", "-S"),
    "timeout": ("--signal=", "--kill-after=", "-s", "-k"),
    "nice": ("-n",),
    "stdbuf": ("-i", "-o", "-e"),
    "sudo": ("-",),
    "caffeinate": ("-",),
}

# tmux のグローバルオプション。usage: tmux [-2CDlNuVv] [-c shell-command] [-f file]
# [-L socket-name] [-S socket-path] [-T features] [command [flags]]
# `-u` を `-L` と読み違えたのが 2026-09-09 の事故の一因なので、値を取らないフラグは列挙で持つ。
TMUX_FLAG_CHARS = frozenset("2CDlNquvV")
TMUX_VALUE_CHARS = frozenset("cfT")
TMUX_SOCKET_CHARS = frozenset("LS")


def emit(text):
    # stderr が閉じられていても判定結果 (exit 2) だけは必ず返す。書けないときに例外を
    # 投げると外側の except からまた deny() が呼ばれ、exit 1 で終わっていた (実測: 2>&- で rc=1)。
    try:
        sys.stderr.write(text + "\n")
    except Exception:
        pass


def deny(reason):
    emit("[tmux kill ガード / Issue #314] このコマンドは実行しません。")
    emit("理由: " + reason)
    emit("")
    emit("次に取るべき行動:")
    emit("  1. 別綴り (kill-sess / kill-ser など) や別経路へ書き換えて再試行しないこと。")
    emit("     直すのは綴りではなく隔離のほう。")
    emit("  2. 自分が作った隔離 server の後始末は、名前を完全一致で指定する:")
    emit("       env -u TMUX tmux -L <一意名> kill-session -t '=<自分が作った名前>'")
    emit("  3. 既定 server への write が本当に必要なら、自分で実行せずユーザーに依頼すること。")
    emit("     このフックに逃し道は無い。")
    emit("")
    emit("背景: 2026-09-09、隔離したつもりの kill-server がユーザーの既定 server へ飛び、")
    emit("      全 session が消えた。詳細は CLAUDE.md「外部 CLI を計測するときの作法」。")
    try:
        sys.stderr.flush()
    except Exception:
        pass
    # インタプリタ終了時の後片付け (stderr の flush 失敗など) で終了コードが変わらないよう、
    # ここだけは os._exit で抜ける。exit 2 以外はツール呼び出しを止めない。
    os._exit(2)


def extract_paren(s, start, end):
    """s[start:end] から、対応する `)` までを取り出す。深さだけを数え、引用符は解釈しない。

    戻り値は (中身, 閉じ括弧の次の位置, 閉じたか)。
    """
    depth = 1
    i = start
    while i < end:
        match = _PAREN_RE.search(s, i, end)
        if match is None:
            return s[start:end], end, False
        pos = match.start()
        if s[pos] == "(":
            depth += 1
        else:
            depth -= 1
            if depth == 0:
                return s[start:pos], pos + 1, True
        i = pos + 1
    return s[start:end], end, False


class Lexer:
    """コマンド文字列を simple command の列へ分解する。

    引用符は剥がす。変数展開は行わない (`c=kill-server; tmux $c` の類は Issue #314 の
    スコープ外)。コマンド置換とプロセス置換の中身は queue へ回して別途検査する。
    """

    def __init__(self, text, queue):
        self.s = text
        self.n = len(text)
        self.i = 0
        self.queue = queue
        self.cur = []
        self.have = False
        self.skip_words = 0
        self.words = []
        self.commands = []
        self.heredocs = []
        self.unbalanced = False

    def flush_word(self):
        if self.have or self.cur:
            if self.skip_words > 0:
                # here-string (`<<<`) のデータとリダイレクト先。どちらもコマンドではない。
                self.skip_words -= 1
            else:
                self.words.append("".join(self.cur))
            self.cur = []
            self.have = False

    def end_command(self):
        self.flush_word()
        if self.words:
            self.commands.append(self.words)
            self.words = []

    def drop_fd_prefix(self):
        """`2>file` の `2` のように、リダイレクト記号の直前に付いた fd 番号は語ではない。"""
        if self.have and self.cur:
            word = "".join(self.cur)
            if word.isdigit():
                self.cur = []
                self.have = False

    def queue_substitutions(self, start, end):
        """範囲内のコマンド置換の中身だけを queue へ回す。範囲はスライスせず添字で走る。"""
        s = self.s
        i = start
        while i < end:
            match = _SUB_RE.search(s, i, end)
            if match is None:
                return
            pos = match.start()
            char = s[pos]
            if char == "\\":
                # escape された `$` やバッククォートは bash も展開しない。ここを見ないと、
                # 展開を止める書き方 (`\$(...)`) を文書に書いただけで拒否になる。
                i = pos + 2
            elif char == "$":
                if pos + 1 < end and s[pos + 1] == "(":
                    inner, nxt, ok = extract_paren(s, pos + 2, end)
                    if not ok:
                        self.unbalanced = True
                    self.queue.append(inner)
                    i = nxt
                else:
                    i = pos + 1
            else:
                close = s.find("`", pos + 1, end)
                if close == -1:
                    self.unbalanced = True
                    self.queue.append(s[pos + 1:end])
                    return
                self.queue.append(s[pos + 1:close])
                i = close + 1

    def consume_heredoc_bodies(self):
        """改行の直後から、待機中の heredoc 本文を読み飛ばす。

        本文はデータであってコマンド列ではない。ここを解析すると、事故を記録する文書や
        コード例を heredoc で書くだけで拒否されてしまう。
        """
        s, n = self.s, self.n
        for delim, strip, quoted in self.heredocs:
            body_start = self.i
            body_end = n
            while self.i < n:
                line_start = self.i
                newline = s.find("\n", self.i)
                if newline == -1:
                    line_end = n
                    self.i = n
                else:
                    line_end = newline
                    self.i = newline + 1
                compare_start = line_start
                if strip:
                    while compare_start < line_end and s[compare_start] == "\t":
                        compare_start += 1
                if s[compare_start:line_end] == delim:
                    body_end = line_start
                    break
            else:
                # 区切り語が現れないまま入力が尽きた。シェル自身も構文エラーになる形なので、
                # 本文を最後まで読み飛ばすだけにする。
                body_end = n
            # 区切り語が引用されていなければ本文中の展開は起きる。置換の中身だけは検査へ回す。
            if not quoted:
                self.queue_substitutions(body_start, body_end)
        self.heredocs = []

    def read_heredoc_header(self):
        """`<<` の直後から区切り語を読む。`<<<` (here-string) なら True を返す。"""
        s, n = self.s, self.n
        self.i += 2
        if self.i < n and s[self.i] == "<":
            self.i += 1
            self.skip_words += 1
            return True
        strip = False
        if self.i < n and s[self.i] == "-":
            strip = True
            self.i += 1
        while self.i < n and s[self.i] in " \t":
            self.i += 1
        delim = []
        quoted = False
        while self.i < n:
            char = s[self.i]
            if char in " \t\n;&|<>":
                break
            if char in "'\"":
                # 引用された区切り語は本文中の展開を止める
                quoted = True
            elif char == "\\":
                quoted = True
                self.i += 1
                if self.i < n:
                    delim.append(s[self.i])
            else:
                delim.append(char)
            self.i += 1
        self.heredocs.append(("".join(delim), strip, quoted))
        return False

    def run(self):
        s, n = self.s, self.n
        single = False
        double = False
        while self.i < n:
            # 特殊文字に当たるまでをまとめて取り込む
            if single:
                match = _SQ_RE.search(s, self.i)
            elif double:
                match = _DQ_SPECIAL_RE.search(s, self.i)
            else:
                match = _SPECIAL_RE.search(s, self.i)
            if match is None:
                self.cur.append(s[self.i:])
                self.have = True
                self.i = n
                break
            if match.start() > self.i:
                self.cur.append(s[self.i:match.start()])
                self.have = True
                self.i = match.start()
            char = s[self.i]

            if single:
                if char == "'":
                    single = False
                else:
                    self.cur.append(char)
                self.i += 1
                continue

            if char == "\\":
                self.i += 1
                if self.i < n:
                    if s[self.i] == "\n":
                        # 行継続。`\` と改行はシェルでは 1 文字も残らない。
                        self.i += 1
                        continue
                    self.cur.append(s[self.i])
                    self.have = True
                    self.i += 1
                continue

            if not double and char == "<" and self.i + 1 < n and s[self.i + 1] == "<":
                self.drop_fd_prefix()
                self.flush_word()
                self.read_heredoc_header()
                continue

            # プロセス置換 `<(…)` / `>(…)`。中身はコマンド列なので検査へ回す。
            if not double and char in "<>" and self.i + 1 < n and s[self.i + 1] == "(":
                self.flush_word()
                inner, nxt, ok = extract_paren(s, self.i + 2, n)
                if not ok:
                    self.unbalanced = True
                self.queue.append(inner)
                self.i = nxt
                continue

            # リダイレクト。**区切りにしない** — 区切ると `tmux 2>/dev/null kill-server` の
            # ようにコマンド名と引数の間へ挟まった形で、後ろの kill-… が別のコマンドとして
            # 素通りする。`&>` `>|` `>&` `>>` も同じ扱い。
            if not double and (
                char in "<>"
                or (char == "&" and self.i + 1 < n and s[self.i + 1] == ">")
            ):
                self.drop_fd_prefix()
                self.flush_word()
                if char == "&":
                    self.i += 1
                self.i += 1
                while self.i < n and s[self.i] in "<>&|":
                    self.i += 1
                self.skip_words += 1
                continue

            if not double and char == "\n":
                self.end_command()
                self.i += 1
                if self.heredocs:
                    self.consume_heredoc_bodies()
                continue

            if char == "$" and self.i + 1 < n and s[self.i + 1] == "(":
                inner, nxt, ok = extract_paren(s, self.i + 2, n)
                if not ok:
                    self.unbalanced = True
                self.queue.append(inner)
                self.have = True
                self.i = nxt
                continue

            if char == "`":
                close = s.find("`", self.i + 1)
                if close == -1:
                    self.unbalanced = True
                    self.queue.append(s[self.i + 1:])
                    self.have = True
                    self.i = n
                    continue
                self.queue.append(s[self.i + 1:close])
                self.have = True
                self.i = close + 1
                continue

            if double:
                if char == '"':
                    double = False
                else:
                    self.cur.append(char)
                self.i += 1
                continue

            if char == "'":
                single = True
                self.have = True
            elif char == '"':
                double = True
                self.have = True
            elif char in " \t":
                self.flush_word()
            elif char in ";&|()":
                self.end_command()
            elif char == "#":
                if not self.have and not self.cur:
                    newline = s.find("\n", self.i)
                    self.i = n if newline == -1 else newline
                    continue
                self.cur.append(char)
                self.have = True
            else:
                self.cur.append(char)
                self.have = True
            self.i += 1

        self.end_command()
        if single or double:
            self.unbalanced = True
        return self.commands


def known_prefix_option(cmd, word):
    if word in PREFIX_FLAG_OPTIONS.get(cmd, ()):
        return True
    for prefix in PREFIX_FLAG_PREFIXES.get(cmd, ()):
        if word.startswith(prefix) and len(word) > len(prefix):
            return True
        if word == prefix:
            return True
    return False


def skip_prefix_options(cmd, words, idx, queue):
    """前置コマンドのオプションを読み飛ばす。戻り値は (次の添字, 解釈できなかったか)。"""
    while idx < len(words):
        word = words[idx]
        if word == "--":
            return idx + 1, False
        if word == "-" or not word.startswith("-"):
            return idx, False
        if cmd == "env":
            # BSD env の `-S` は値を**コマンド列として分割実行する** (実測 2026-09-09:
            # `env -S 'echo split works'` が実行される)。値を捨てるとその中の tmux が
            # 見えなくなるので、コマンド文字列として検査へ回す。
            # GNU の `--split-string=` も同形 (macOS の env は受け付けない: 実測で
            # `env: illegal option -- s`) だが、環境に依存しないよう同じ扱いにする。
            if word == "-S" and idx + 1 < len(words):
                queue.append(words[idx + 1])
                idx += 2
                continue
            if word.startswith("-S") and len(word) > 2:
                queue.append(word[2:])
                idx += 1
                continue
            if word.startswith("--split-string="):
                queue.append(word[len("--split-string="):])
                idx += 1
                continue
        if word in PREFIX_VALUE_OPTIONS.get(cmd, ()):
            idx += 2
            continue
        if known_prefix_option(cmd, word):
            idx += 1
            continue
        return idx, True
    return idx, False


# 値を次の語で取るシェルのオプション。`bash -euo pipefail -c '…'` の `pipefail` を
# 「オプションではない語 = スクリプトファイル」と誤読して降りると、`-c` の検査が丸ごと
# 外れる (実測 2026-09-09: rc=0 で偽 tmux に kill-server が届いた)。
SHELL_VALUE_OPTIONS = frozenset(("-o", "+o", "-O", "+O", "--rcfile", "--init-file"))


def queue_shell_script(words, idx, queue):
    """`bash -c '<コマンド文字列>'` の中身を検査へ回す。

    スクリプトファイルの実行 (`bash /tmp/x.sh`) や、シェルに文字列を食わせる形
    (`bash <<EOF …` / `… | bash`) は Issue #314 が扱わない経路なので素通りさせる。
    """
    i = idx + 1
    while i < len(words):
        word = words[i]
        if word == "--":
            return
        if not word.startswith("-") and not word.startswith("+"):
            # スクリプトファイルの実行 → スコープ外
            return
        if word in SHELL_VALUE_OPTIONS:
            i += 2
            continue
        if word.startswith("--"):
            i += 1
            continue
        letters = word[1:]
        if "c" in letters:
            # `-c` / `-ec` / `-cx` のいずれでも、コマンド文字列は次の語に来る。
            if i + 1 < len(words):
                queue.append(words[i + 1])
            return
        if letters and letters[-1] in "oO":
            # `-euo pipefail` のように、クラスタの末尾が値を取る
            i += 2
            continue
        i += 1


def has_kill_token(words):
    return any(word.startswith("kill-se") for word in words)


def inspect_tmux(words, idx, queue):
    """tmux のグローバルオプションを読み、socket の指定だけを取り出して判定する。"""
    i = idx + 1
    l_set = False
    l_name = ""
    s_set = False
    failed = False
    while i < len(words):
        word = words[i]
        if word == "--":
            i += 1
            break
        if word == "-":
            failed = True
            break
        if not word.startswith("-"):
            break
        j = 1
        while j < len(word):
            char = word[j]
            if char in TMUX_FLAG_CHARS:
                j += 1
                continue
            if char in TMUX_VALUE_CHARS:
                # 値は取るが socket の選択には効かない。ただし `-c` の値は既定シェル経由で
                # **実行される** (実測 2026-09-09: `tmux -L <一意名> -c "touch M"` が M を作り、
                # その socket に server は立たなかった)。外側が tmux である以上ここは
                # このガードが所有する解析路なので、中身をコマンド文字列として検査へ回す。
                if j + 1 < len(word):
                    value = word[j + 1:]
                else:
                    i += 1
                    value = words[i] if i < len(words) else ""
                if char == "c":
                    queue.append(value)
                break
            if char in TMUX_SOCKET_CHARS:
                if j + 1 < len(word):
                    value = word[j + 1:]
                else:
                    i += 1
                    if i < len(words):
                        value = words[i]
                    else:
                        value = ""
                        failed = True
                if char == "L":
                    l_set = True
                    l_name = value
                else:
                    s_set = True
                break
            failed = True
            break
        if failed:
            break
        i += 1

    # オプションを読み違えていたら、どこからが引数か分からない。全語を対象に見る。
    start = idx + 1 if failed else i
    rest = words[start:]
    has_server = False
    has_kill = False
    for word in rest:
        # tmux はコマンド名の接頭辞一致を受け付ける (実測: `kill-sess` が通る)。
        # `kill-se` / `kill-s` は kill-server と kill-session の間で曖昧 (実測)。
        if word.startswith("kill-ser") or word == "kill-se":
            has_kill = True
            has_server = True
        elif word.startswith("kill-se"):
            has_kill = True

    if not has_kill:
        return
    if failed:
        deny("tmux のグローバルオプションを解釈できず、隔離 socket の指定を確認できません")
    if has_server:
        # -L 付きでも拒否する。`-L` は `$TMUX` に勝つ (実測) ので隔離自体は成立しうるが、
        # Bash から kill-server を打つ正当な経路がリポジトリに無い (統合テストの kill-server は
        # swift test プロセスの内部でフックからは見えない) ため、方針として一律で止める。
        deny(
            "tmux kill-server は Bash ツール経由では一律に拒否します "
            "(-L の有無によらない方針。Bash から打つ正当な経路が無いため)"
        )
    if s_set:
        deny(
            "-S (socket path 直接指定) を伴う kill-se* は、パスによらず一律に拒否します "
            "(-L <一意名> を使ってください)"
        )
    if not l_set:
        deny(
            "kill-session に -L がありません "
            "($TMUX や TMUX_TMPDIR の状態しだいで既定 server へ着地します)"
        )
    # socket 名の解決はファイルシステム任せで、macOS の APFS では大文字小文字を区別しない
    # (実測: -L awt-gc-Case で起こした server に -L AWT-GC-CASE が届く)。
    if l_name.lower() == "default" or l_name == "":
        deny(
            "-L '%s' は既定 server を指します "
            "(実測: -L default / -L DEFAULT の socket_path はどちらも "
            "/private/tmp/tmux-<uid>/default)" % l_name
        )
    if "/" in l_name:
        # `/` を含む値は socket ディレクトリからの相対パスとして解決される
        # (実測: -L ./default も -L ../tmux-501/default も既定 server の session を返した)。
        deny(
            "-L の値にパス区切り '/' が含まれています (実測: -L ./default は既定 server へ届く)。"
            "-L には '/' を含まない一意な名前だけを使ってください"
        )


def inspect_command(words, queue):
    """simple command を検査する。tmux の破壊操作を見つけたら deny() で終了する。"""
    idx = 0
    while idx < len(words) and _ASSIGN_RE.match(words[idx]):
        idx += 1
    while idx < len(words):
        base = words[idx].rsplit("/", 1)[-1]
        if base in KEYWORDS:
            idx += 1
            while idx < len(words) and _ASSIGN_RE.match(words[idx]):
                idx += 1
            continue
        if base in PREFIX_COMMANDS:
            idx += 1
            idx, failed = skip_prefix_options(base, words, idx, queue)
            if not failed and base == "env":
                while idx < len(words) and _ASSIGN_RE.match(words[idx]):
                    idx += 1
            if not failed and base == "timeout" and idx < len(words):
                # 時間の指定を 1 語ぶん読み飛ばす
                idx += 1
            if failed:
                if has_kill_token(words):
                    deny(
                        "コマンドの前置 (env / timeout など) を解釈できず、"
                        "tmux の呼び出しか判定できません"
                    )
                return
            continue
        if base in SHELL_COMMANDS:
            queue_shell_script(words, idx, queue)
            return
        if base in EVAL_COMMANDS:
            # eval は残りの語を空白で連ねてシェルに再解釈させる。その文字列をそのまま
            # 検査へ回す (「残りの語に kill-se があれば deny」ではなく中身を見るのは、
            # `eval "rg kill-server"` のような無害な形を誤検知しないため)。
            queue.append(" ".join(words[idx + 1:]))
            return
        if base == "tmux":
            inspect_tmux(words, idx, queue)
            return
        return


def analyze(command):
    queue = [command]
    qi = 0
    while qi < len(queue):
        text = queue[qi]
        qi += 1
        if "kill-se" not in text:
            continue
        lexer = Lexer(text, queue)
        for words in lexer.run():
            inspect_command(words, queue)
        if lexer.unbalanced:
            deny(
                "引用符またはコマンド置換が閉じておらず、コマンドを分解できません "
                "(判定不能のため拒否)"
            )
        if len(queue) > MAX_QUEUED_STRINGS:
            # 打ち切って通すと、上限より後ろの置換が黙って検査されないまま実行される。
            deny(
                "コマンド置換の数が上限 (%d) を超えており、すべてを検査できません "
                "(判定不能のため拒否)" % MAX_QUEUED_STRINGS
            )


def main():
    payload = sys.stdin.read()
    try:
        data = json.loads(payload)
    except Exception:
        deny("stdin を hook JSON として解釈できません (判定不能のため拒否)")
    if not isinstance(data, dict):
        deny("stdin を hook JSON として解釈できません (判定不能のため拒否)")

    # matcher が "Bash" 完全一致なので通常は発火しないが、設定を変えたときの保険。
    tool_name = data.get("tool_name")
    if isinstance(tool_name, str) and tool_name != "Bash":
        return 0

    tool_input = data.get("tool_input")
    command = tool_input.get("command") if isinstance(tool_input, dict) else None
    if not isinstance(command, str):
        deny("hook JSON から tool_input.command を文字列として取り出せません (判定不能のため拒否)")

    # kill-se を含まないコマンドは解析対象にしない。ここで通す文字列は、どう解析しても
    # tmux の破壊操作にはならない。誤検知でふつうの作業を塞がないための足切りでもある。
    if "kill-se" not in command:
        return 0

    if len(command) > MAX_COMMAND_CHARS:
        deny(
            "コマンド文字列が長すぎて (%d 文字 > %d) hook の timeout 内に判定しきれない"
            "おそれがあります。長い本文は Write ツールでファイルへ書き、"
            "scripts/wf-issue-comment.sh と scripts/wf-pr-create.sh は -F/--body-file、"
            "scripts/wf-pr-edit.sh は -B/--body-file または -A/--append-file で渡してください "
            "(scripts/wf-issue-create.sh には body-file オプションが無いので、"
            "空の本文で作ってから wf-issue-comment.sh -F で追記する)"
            % (len(command), MAX_COMMAND_CHARS)
        )

    analyze(command)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except BaseException as exc:  # noqa: BLE001 - 判定できない以上は拒否側へ倒す
        deny("ガード自身が異常終了したため判定できませんでした: %r" % (exc,))

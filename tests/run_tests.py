#!/usr/bin/env python3
"""Test suite for zsh-quickmenu.

Runs two kinds of checks:
  * plain subprocess tests for config loading, filtering and placeholders
  * pty-driven tests that actually drive the interactive TUI with keystrokes

Usage:  python3 tests/run_tests.py
"""

from __future__ import annotations

import fcntl
import os
import pty
import select
import shutil
import struct
import subprocess
import sys
import tempfile
import termios
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLUGIN = os.path.join(ROOT, "quickmenu.plugin.zsh")

# CI runners are slower than a laptop; QM_TEST_DELAY stretches every wait.
DELAY = float(os.environ.get("QM_TEST_DELAY", "1"))

PASS, FAIL = [], []


def check(name: str, ok: bool, detail: str = "") -> None:
    if ok:
        PASS.append(name)
        print(f"  \033[32mok\033[0m   {name}")
    else:
        FAIL.append(name)
        print(f"  \033[31mFAIL\033[0m {name}")
        if detail:
            for line in detail.rstrip().splitlines():
                print(f"       {line}")


class Sandbox:
    """A throwaway HOME + working directory with a known menu config."""

    def __init__(self, menu: str | None = None, files: list[str] | None = None,
                 git: bool = False, configs: dict[str, str] | None = None):
        self.dir = tempfile.mkdtemp(prefix="quickmenu-test-")
        self.home = os.path.join(self.dir, "home")
        self.work = os.path.join(self.dir, "work")
        self.cfg = os.path.join(self.home, ".config", "quickmenu")
        os.makedirs(self.cfg)
        os.makedirs(self.work)
        if menu is not None:
            self.write_config("menu.zsh", menu)
        for name, content in (configs or {}).items():
            self.write_config(name, content)
        for f in files or []:
            path = os.path.join(self.work, f)
            os.makedirs(path) if f.endswith("/") else open(path, "w").close()
        if git:
            subprocess.run(["git", "init", "-q"], cwd=self.work, check=True)

    def write_config(self, name: str, content: str) -> str:
        path = os.path.join(self.cfg, name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as fh:
            fh.write(content)
        return path

    def read_config(self, name: str) -> str:
        with open(os.path.join(self.cfg, name)) as fh:
            return fh.read()

    def env(self, **extra) -> dict:
        env = dict(os.environ)
        env.update(
            HOME=self.home,
            TERM="xterm-256color",
            QUICKMENU_NO_COLOR="1",
            ZDOTDIR=self.home,
        )
        env.pop("QUICKMENU_PICKER", None)
        env.update(extra)
        return env

    def close(self) -> None:
        shutil.rmtree(self.dir, ignore_errors=True)


def zsh(sandbox: Sandbox, script: str, **env) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["zsh", "-f", "-c", f"source {PLUGIN!r}\n{script}"],
        cwd=sandbox.work,
        env=sandbox.env(**env),
        capture_output=True,
        text=True,
        timeout=30,
    )


def zsh_pty(sandbox: Sandbox, script: str, keys: list[bytes], *, timeout: float = 15.0,
            argv: list[str] | None = None, settle: float = 0.9, **env):
    """Run a zsh snippet attached to a pty and feed it keystrokes."""
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))

    def attach_tty() -> None:
        # New session, and make the pty our controlling terminal so /dev/tty works.
        os.setsid()
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)

    cmd = argv if argv else ["zsh", "-f", "-c", f"source {PLUGIN!r}\n{script}"]

    proc = subprocess.Popen(
        cmd,
        stdin=slave,
        stdout=slave,
        stderr=slave,
        cwd=sandbox.work,
        env=sandbox.env(**env),
        preexec_fn=attach_tty,
        close_fds=True,
    )
    os.close(slave)

    captured = bytearray()

    def drain(seconds: float) -> None:
        end = time.time() + seconds
        while time.time() < end:
            try:
                r, _, _ = select.select([master], [], [], 0.05)
                if r:
                    chunk = os.read(master, 65536)
                    if not chunk:
                        return
                    captured.extend(chunk)
            except OSError:
                return

    drain(settle * DELAY)  # let the menu draw
    for key in keys:
        if proc.poll() is not None:
            break
        try:
            os.write(master, key)
        except OSError:
            break
        drain(0.35 * DELAY)

    deadline = time.time() + timeout * DELAY
    while proc.poll() is None and time.time() < deadline:
        drain(0.2)
    if proc.poll() is None:
        proc.kill()
    drain(0.3)
    os.close(master)
    return proc.wait(), captured.decode("utf-8", "replace")


MENU = r"""
qm_item -g open  'Launch Code'          'code .'
qm_item -g open  'Launch Finder'        'open .'
qm_item -g open  'Launch Xcode project' 'open {{file:*.xcodeproj *.xcworkspace}}'
qm_item -g git   'Commit everything'    'git add -A && git commit -m {{prompt:Message=Automated commit}}'
qm_item -g dev   'Only in git'          'git status -sb' -c 'git rev-parse --is-inside-work-tree'
qm_item -g dev   'Edit me'              'echo edited' -e
qm_item -g dev   'Dangerous'            'echo boom' -y
"""

UP, DOWN, ENTER, ESC, TAB = b"\x1b[A", b"\x1b[B", b"\r", b"\x1b", b"\t"


def main() -> int:
    print("zsh-quickmenu test suite\n")

    # ---------------------------------------------------------------- basics
    print("config + listing")
    sb = Sandbox(MENU)
    try:
        r = zsh(sb, "quickmenu --list")
        check("lists items", "Launch Code" in r.stdout, r.stdout + r.stderr)
        check("hides git-only item outside a repo", "Only in git" not in r.stdout, r.stdout)
        check("group prefix is shown", "open: Launch Finder" in r.stdout, r.stdout)

        r = zsh(sb, "quickmenu --help")
        check("--help works", "usage: qm" in r.stdout, r.stdout + r.stderr)

        r = zsh(sb, "qm --list")
        check("qm alias works", "Launch Code" in r.stdout, r.stdout + r.stderr)
    finally:
        sb.close()

    sb = Sandbox(MENU, git=True)
    try:
        r = zsh(sb, "quickmenu --list")
        check("shows git-only item inside a repo", "Only in git" in r.stdout, r.stdout)
    finally:
        sb.close()

    # ------------------------------------------------------------ resolution
    print("\nplaceholders")
    sb = Sandbox(MENU, files=["MyApp.xcodeproj/"])
    try:
        r = zsh(sb, "quickmenu --print xcode")
        check("{{file}} with one match resolves silently",
              r.stdout.strip() == "open MyApp.xcodeproj", r.stdout + r.stderr)

        r = zsh(sb, "quickmenu --print finder")
        check("single query match runs without the menu",
              r.stdout.strip() == "open .", r.stdout + r.stderr)

        r = zsh(sb, "quickmenu --print 'no such entry'")
        check("unknown query fails cleanly",
              r.returncode != 0 and "nothing matches" in r.stderr, r.stdout + r.stderr)

        r = zsh(sb, "quickmenu --print -n 2")
        check("--index picks by number", r.stdout.strip() == "open .", r.stdout + r.stderr)

        r = zsh(sb, "quickmenu --print -n 99")
        check("--index rejects out of range",
              r.returncode != 0 and "out of range" in r.stderr, r.stdout + r.stderr)

        inp = os.path.join(sb.dir, "in.txt")
        with open(inp, "w") as fh:
            fh.write("\n")
        r = zsh(sb, "quickmenu --print commit",
                QUICKMENU_TTY_IN=inp, QUICKMENU_TTY_OUT="/dev/null")
        check("{{prompt}} falls back to its default",
              r.stdout.strip() == r"git add -A && git commit -m Automated\ commit",
              r.stdout + r.stderr)

        with open(inp, "w") as fh:
            fh.write("it's a fix; rm -rf /\n")
        r = zsh(sb, "quickmenu --print commit",
                QUICKMENU_TTY_IN=inp, QUICKMENU_TTY_OUT="/dev/null")
        check("{{prompt}} shell-quotes user input",
              r"rm\ -rf\ /" in r.stdout and r"\;" in r.stdout, r.stdout + r.stderr)
    finally:
        sb.close()

    # -------------------------------------------------------------- dumb tty
    print("\nnumbered fallback (TERM=dumb)")
    sb = Sandbox(MENU)
    try:
        r = subprocess.run(
            ["zsh", "-f", "-c", f"source {PLUGIN!r}\nquickmenu --print"],
            cwd=sb.work, env=sb.env(TERM="dumb"), input="2\n",
            capture_output=True, text=True, timeout=30,
        )
        check("numbered fallback selects by number",
              r.stdout.strip() == "open .", r.stdout + r.stderr)
    finally:
        sb.close()

    # ------------------------------------------------------------- interactive
    print("\ninteractive TUI (pty)")
    sb = Sandbox(MENU, files=["MyApp.xcodeproj/", "Other.xcodeproj/"])
    out = os.path.join(sb.dir, "out.txt")
    script = f"quickmenu --print > {out!r}"

    def result() -> str:
        try:
            with open(out) as fh:
                return fh.read().strip()
        except FileNotFoundError:
            return "<no file>"

    def reset() -> None:
        if os.path.exists(out):
            os.remove(out)

    try:
        reset()
        rc, screen = zsh_pty(sb, script, [ENTER])
        check("enter runs the highlighted item", result() == "code .", result() + "\n" + screen[-400:])
        check("menu renders a header", "quickmenu" in screen, screen[-400:])
        check("menu renders hint line", "esc" in screen, screen[-400:])

        reset()
        rc, screen = zsh_pty(sb, script, [DOWN, ENTER])
        check("arrow down moves the cursor", result() == "open .", result() + "\n" + screen[-400:])

        reset()
        # the last item is "Dangerous", which asks for confirmation
        rc, screen = zsh_pty(sb, script, [UP, ENTER, b"y", b"\r"])
        check("arrow up wraps to the last item", result() == "echo boom", result() + "\n" + screen[-400:])

        reset()
        rc, screen = zsh_pty(sb, script, [b"\x0e", ENTER])
        check("ctrl-n moves down", result() == "open .", result() + "\n" + screen[-400:])

        reset()
        rc, screen = zsh_pty(sb, script, [b"2"])
        check("digit selects instantly", result() == "open .", result() + "\n" + screen[-400:])
    finally:
        sb.close()

    # digit shortcuts always address the visible rows, even after scrolling
    numbered = "\n".join(f"qm_item 'Item {n}' 'echo cmd{n}'" for n in range(1, 13))
    sb = Sandbox(numbered)
    out = os.path.join(sb.dir, "out.txt")
    script = f"quickmenu --print > {out!r}"

    def result() -> str:  # noqa: F811 - rebound for the new sandbox
        try:
            with open(out) as fh:
                return fh.read().strip()
        except FileNotFoundError:
            return "<no file>"

    def reset() -> None:  # noqa: F811
        if os.path.exists(out):
            os.remove(out)

    try:
        reset()
        rc, screen = zsh_pty(sb, script, [b"0"])
        check("0 selects the tenth row", result() == "echo cmd10", result() + "\n" + screen[-500:])

        reset()
        rc, screen = zsh_pty(sb, script, [DOWN] * 6 + [b"1"], QUICKMENU_HEIGHT="5")
        check("digits follow the window after scrolling",
              result() == "echo cmd3", result() + "\n" + screen[-500:])

        reset()
        rc, screen = zsh_pty(sb, script, [DOWN] * 6 + [ENTER], QUICKMENU_HEIGHT="5")
        check("scrolling keeps the cursor on the right item",
              result() == "echo cmd7", result() + "\n" + screen[-500:])
    finally:
        sb.close()

    sb = Sandbox(MENU, files=["MyApp.xcodeproj/", "Other.xcodeproj/"])
    out = os.path.join(sb.dir, "out.txt")
    script = f"quickmenu --print > {out!r}"

    def result() -> str:  # noqa: F811
        try:
            with open(out) as fh:
                return fh.read().strip()
        except FileNotFoundError:
            return "<no file>"

    def reset() -> None:  # noqa: F811
        if os.path.exists(out):
            os.remove(out)

    try:
        reset()
        rc, screen = zsh_pty(sb, script, [b"f", b"i", b"n", ENTER])
        check("typing filters the list", result() == "open .", result() + "\n" + screen[-400:])

        reset()
        # "cmm" fuzzy-matches several commands; the label match must win
        rc, screen = zsh_pty(sb, script, [b"c", b"o", b"m", b"m", ENTER, b"\r"])
        check("label matches rank above loose fuzzy matches",
              result().startswith("git add -A"), result() + "\n" + screen[-500:])

        reset()
        rc, screen = zsh_pty(sb, script, [b"f", b"i", b"n", b"\x7f", b"\x7f", b"\x7f", ENTER])
        check("backspace restores the full list", result() == "code .", result() + "\n" + screen[-400:])

        reset()
        rc, screen = zsh_pty(sb, script, [b"z", b"q", b"x", b"\x15", ENTER])
        check("ctrl-u clears the query", result() == "code .", result() + "\n" + screen[-400:])

        reset()
        rc, screen = zsh_pty(sb, script, [b"z", b"q", b"x", ENTER, ESC])
        check("enter on an empty list does nothing", result() == "<no file>" or result() == "",
              result() + "\n" + screen[-400:])

        reset()
        rc, screen = zsh_pty(sb, script, [ESC])
        check("esc cancels", rc != 0 and result() in ("", "<no file>"), f"rc={rc} {result()}")

        reset()
        rc, screen = zsh_pty(sb, script, [b"\x03"])
        check("ctrl-c cancels", rc != 0 and result() in ("", "<no file>"), f"rc={rc} {result()}")

        reset()
        rc, screen = zsh_pty(sb, script, [TAB])
        check("tab selects for editing", result() == "code .", result() + "\n" + screen[-400:])

        # nested picker: two .xcodeproj dirs -> second menu appears
        reset()
        rc, screen = zsh_pty(sb, script, [b"x", b"c", b"o", ENTER, DOWN, ENTER])
        check("{{file}} opens a nested picker",
              result() in ("open MyApp.xcodeproj", "open Other.xcodeproj"),
              result() + "\n" + screen[-600:])

        reset()
        rc, screen = zsh_pty(sb, script, [b"x", b"c", b"o", ENTER, b"2"])
        check("nested picker honours digit select",
              result() == "open Other.xcodeproj", result() + "\n" + screen[-600:])

        # confirmation flag
        reset()
        rc, screen = zsh_pty(sb, script, [b"d", b"a", b"n", ENTER, b"n", b"\r"])
        check("-y aborts on 'n'", result() in ("", "<no file>"), result() + "\n" + screen[-400:])

        reset()
        rc, screen = zsh_pty(sb, script, [b"d", b"a", b"n", ENTER, b"y", b"\r"])
        check("-y proceeds on 'y'", result() == "echo boom", result() + "\n" + screen[-400:])

        # terminal is restored afterwards
        rc, screen = zsh_pty(sb, "quickmenu --print > /dev/null; stty -a | head -1", [ENTER])
        check("terminal mode is restored (echo back on)", " echo" in screen and "-echo" not in screen,
              screen[-400:])
    finally:
        sb.close()

    # ------------------------------------------------------- real execution
    print("\nexecution")
    sb = Sandbox("qm_item 'Say hi' 'print hello-from-quickmenu'\nqm_item 'Go up' 'cd ..'")
    try:
        rc, screen = zsh_pty(sb, "quickmenu", [ENTER])
        check("chosen command actually runs", "hello-from-quickmenu" in screen, screen[-400:])
        check("the command is echoed before running", "$ print hello" in screen, screen[-400:])

        rc, screen = zsh_pty(sb, "quickmenu go; pwd", [ENTER])
        check("cd affects the calling shell",
              screen.rstrip().endswith(os.path.dirname(sb.work)) or os.path.dirname(sb.work) in screen,
              screen[-400:])
    finally:
        sb.close()

    # ---------------------------------------------------------- .conf format
    print("\n.conf config format")
    CONF = """\
# a comment
; also a comment

[open]
Launch Code   = code .
Launch Finder = open .
Launch Xcode project = open {{file:*.xcodeproj *.xcworkspace}}
.desc = ios swift mobile

[git]
.if = git rev-parse --is-inside-work-tree

Commit everything = git add -A && git commit -m "Automated commit"
Discard all = git reset --hard
.confirm = yes
Only when clean = echo clean
.if = [[ -z $(git status --porcelain) ]]

[misc]
Quoted = "echo  spaced  "
Long one = echo one \\
  two \\
  three
Has equals = FOO=bar env | grep FOO
Edit me = echo editme
.edit = yes
Regrouped = echo regrouped
.group = elsewhere
"""
    sb = Sandbox(configs={"menu.conf": CONF}, git=True)
    try:
        r = zsh(sb, "quickmenu --list")
        out = r.stdout
        check(".conf items load", "open: Launch Code" in out, out + r.stderr)
        check(".conf [section] becomes the group", "open: Launch Finder" in out, out)
        check(".conf .group overrides the section", "elsewhere: Regrouped" in out, out)
        check(".conf comments are ignored",
              "a comment" not in out and "also a comment" not in out, out)
        check(".conf keeps '=' inside commands", "FOO=bar env | grep FOO" in out, out)
        check(".conf joins continued lines", "echo one two three" in out, out)
        check(".conf strips surrounding quotes", "echo  spaced" in out, out)
        check(".conf section .if shows git items inside a repo",
              "git: Commit everything" in out, out)

        r = zsh(sb, "quickmenu --list 'ios swift'")
        check(".conf .desc is searchable",
              "Launch Xcode project" in r.stdout and "Launch Finder" not in r.stdout,
              r.stdout + r.stderr)

        r = zsh(sb, "quickmenu --print 'Launch Xcode'")
        check(".desc does not leak into the command",
              "ios swift" not in r.stdout, r.stdout + r.stderr)
    finally:
        sb.close()

    sb = Sandbox(configs={"menu.conf": CONF})  # not a git repo
    try:
        r = zsh(sb, "quickmenu --list")
        check(".conf section .if hides the whole group outside a repo",
              "git:" not in r.stdout and "open: Launch Code" in r.stdout, r.stdout + r.stderr)
    finally:
        sb.close()

    sb = Sandbox(configs={"menu.conf": CONF}, git=True)
    try:
        # section .if and item .if are ANDed; make the tree dirty so the item hides
        open(os.path.join(sb.work, "dirty.txt"), "w").write("x")
        subprocess.run(["git", "add", "."], cwd=sb.work, check=True)
        r = zsh(sb, "quickmenu --list")
        check("item .if is combined with the section .if",
              "Only when clean" not in r.stdout and "git: Commit everything" in r.stdout,
              r.stdout + r.stderr)
    finally:
        sb.close()

    sb = Sandbox(configs={"menu.conf": CONF}, git=True)
    try:
        inp = os.path.join(sb.dir, "in.txt")
        with open(inp, "w") as fh:
            fh.write("n\n")
        r = zsh(sb, "quickmenu --print 'Discard all'",
                QUICKMENU_TTY_IN=inp, QUICKMENU_TTY_OUT="/dev/null")
        check(".conf .confirm asks and honours 'n'",
              r.returncode != 0 and "git reset" not in r.stdout, r.stdout + r.stderr)

        r = zsh(sb, "quickmenu --print 'Commit everything'",
                QUICKMENU_TTY_IN=inp, QUICKMENU_TTY_OUT="/dev/null")
        check(".confirm does not bleed onto the previous item",
              r.returncode == 0 and "git add -A" in r.stdout, r.stdout + r.stderr)
    finally:
        sb.close()

    sb = Sandbox(configs={"menu.conf": "Good = echo good\nthis line is broken\nAlso good = echo also\n"})
    try:
        r = zsh(sb, "quickmenu --list")
        check(".conf reports a bad line but keeps going",
              "echo good" in r.stdout and "echo also" in r.stdout and ":2:" in r.stderr,
              r.stdout + r.stderr)
    finally:
        sb.close()

    # ---------------------------------------------------------- json format
    print("\n.json config format")
    JSON_OBJ = """{
  "items": [
    {"label": "Launch Code", "run": "code .", "group": "open"},
    {"label": "Commit everything",
     "run": "git add -A && git commit -m {{prompt:Message=Automated commit}}",
     "group": "git", "if": "git rev-parse --is-inside-work-tree"},
    {"label": "Dangerous", "run": "echo boom", "confirm": true},
    {"label": "Editable", "run": "echo edit", "edit": true},
    {"label": "Described", "run": "echo described", "desc": "findbykeyword"},
    {"label": "Multi line", "run": "echo a\\necho b"}
  ]
}"""
    JSON_ARR = '[{"label": "From array", "command": "echo arr"}]'

    for backend, extra in (("jq", {}), ("python3", {"QUICKMENU_NO_JQ": "1"})):
        sb = Sandbox(configs={"menu.json": JSON_OBJ}, git=True)
        try:
            env = dict(extra)
            if backend == "python3":
                # hide jq from the shell
                env["PATH"] = ":".join(
                    p for p in sb.env()["PATH"].split(":")
                    if not os.path.exists(os.path.join(p, "jq"))
                )
            r = zsh(sb, "quickmenu --list", **env)
            check(f".json items load ({backend})", "open: Launch Code" in r.stdout,
                  r.stdout + r.stderr)
            check(f".json 'if' is honoured ({backend})",
                  "git: Commit everything" in r.stdout, r.stdout + r.stderr)
            check(f".json keeps embedded newlines ({backend})",
                  "echo a ; echo b" in r.stdout, r.stdout + r.stderr)

            r = zsh(sb, "quickmenu --print findbykeyword", **env)
            check(f".json desc is searchable ({backend})",
                  r.stdout.strip() == "echo described", r.stdout + r.stderr)
        finally:
            sb.close()

    sb = Sandbox(configs={"menu.json": JSON_ARR})
    try:
        r = zsh(sb, "quickmenu --list")
        check(".json accepts a bare array", "From array" in r.stdout, r.stdout + r.stderr)
    finally:
        sb.close()

    sb = Sandbox(configs={"menu.json": JSON_OBJ})
    try:
        inp = os.path.join(sb.dir, "in.txt")
        with open(inp, "w") as fh:
            fh.write("n\n")
        r = zsh(sb, "quickmenu --print Dangerous",
                QUICKMENU_TTY_IN=inp, QUICKMENU_TTY_OUT="/dev/null")
        check(".json confirm:true is honoured", r.returncode != 0, r.stdout + r.stderr)
    finally:
        sb.close()

    sb = Sandbox(configs={"menu.json": "{ this is not json "})
    try:
        r = zsh(sb, "quickmenu --list")
        check(".json reports a parse error clearly",
              r.returncode != 0 and "could not read" in r.stderr, r.stdout + r.stderr)
    finally:
        sb.close()

    # ------------------------------------------------- mixing + discovery
    print("\nconfig discovery")
    sb = Sandbox(
        menu="qm_item 'From zsh' 'echo zsh'",
        configs={
            "menu.conf": "From conf = echo conf\n",
            "menu.json": '[{"label": "From json", "run": "echo json"}]',
            "menu.d/extra.conf": "From snippet = echo snippet\n",
        },
    )
    try:
        r = zsh(sb, "quickmenu --list")
        for fmt in ("conf", "json", "zsh", "snippet"):
            check(f"loads menu from {fmt}", f"From {fmt}" in r.stdout, r.stdout + r.stderr)

        r = zsh(sb, "quickmenu --config")
        check("--config lists every file in order",
              r.stdout.index("menu.conf") < r.stdout.index("menu.json") < r.stdout.index("menu.zsh"),
              r.stdout + r.stderr)
        check("--config names the primary file",
              "primary" in r.stdout and "menu.conf" in r.stdout, r.stdout)
    finally:
        sb.close()

    sb = Sandbox()
    try:
        r = zsh(sb, "quickmenu --list")
        check("a fresh install seeds menu.conf",
              os.path.exists(os.path.join(sb.cfg, "menu.conf")) and "Launch Code" in r.stdout,
              r.stdout + r.stderr)
        check("the shipped template parses without warnings",
              "expected 'Label" not in r.stderr and "unknown setting" not in r.stderr,
              r.stderr)
    finally:
        sb.close()

    sb = Sandbox(configs={"menu.conf": "A = echo a\n"})
    try:
        r = zsh(sb, "quickmenu --add 'Deploy prod' './deploy.sh prod' ops")
        check("--add appends to the .conf", r.returncode == 0 and "added" in r.stderr,
              r.stdout + r.stderr)
        check("--add writes label, command and group",
              "Deploy prod = ./deploy.sh prod" in sb.read_config("menu.conf")
              and ".group = ops" in sb.read_config("menu.conf"),
              sb.read_config("menu.conf"))

        r = zsh(sb, "quickmenu --list")
        check("--add shows up immediately", "ops: Deploy prod" in r.stdout, r.stdout + r.stderr)

        r = zsh(sb, "quickmenu --add 'Bad = label' 'echo x'")
        check("--add rejects '=' in a label",
              r.returncode != 0 and "cannot contain" in r.stderr, r.stdout + r.stderr)

        r = zsh(sb, "quickmenu --add 'Only a label'")
        check("--add needs a command when given args",
              r.returncode != 0 and "usage" in r.stderr, r.stdout + r.stderr)
    finally:
        sb.close()

    sb = Sandbox(configs={"menu.json": JSON_ARR})
    try:
        r = zsh(sb, "quickmenu --add 'X' 'echo x'")
        check("--add refuses to edit a .json config",
              r.returncode != 0 and "only writes .conf" in r.stderr, r.stdout + r.stderr)
    finally:
        sb.close()

    # ------------------------------------------------------- project-local
    print("\nproject-local menus")
    sb = Sandbox(MENU)
    try:
        with open(os.path.join(sb.work, ".quickmenu.zsh"), "w") as fh:
            fh.write("qm_item -g local 'Project build' 'echo project-build'\n")
        r = zsh(sb, "quickmenu --list")
        check("loads ./.quickmenu.zsh", "Project build" in r.stdout, r.stdout + r.stderr)

        sub = os.path.join(sb.work, "a", "b")
        os.makedirs(sub)
        r = subprocess.run(
            ["zsh", "-f", "-c", f"source {PLUGIN!r}\nquickmenu --list"],
            cwd=sub, env=sb.env(), capture_output=True, text=True, timeout=30,
        )
        check("finds .quickmenu.zsh in a parent directory", "Project build" in r.stdout,
              r.stdout + r.stderr)

        os.chmod(os.path.join(sb.work, ".quickmenu.zsh"), 0o666)
        r = zsh(sb, "quickmenu --list")
        check("refuses world-writable config",
              "Project build" not in r.stdout and "writable" in r.stderr, r.stdout + r.stderr)
    finally:
        sb.close()

    sb = Sandbox(MENU)
    try:
        with open(os.path.join(sb.work, ".quickmenu.conf"), "w") as fh:
            fh.write("[local]\nProject build = echo conf-build\n")
        with open(os.path.join(sb.work, ".quickmenu.json"), "w") as fh:
            fh.write('[{"label": "Project deploy", "run": "echo json-deploy", "group": "local"}]')
        r = zsh(sb, "quickmenu --list")
        check("loads ./.quickmenu.conf", "local: Project build" in r.stdout, r.stdout + r.stderr)
        check("loads ./.quickmenu.json", "local: Project deploy" in r.stdout, r.stdout + r.stderr)
        check("project items sit alongside the global menu",
              "Launch Code" in r.stdout, r.stdout)
    finally:
        sb.close()

    sb = Sandbox(MENU)
    try:
        with open(os.path.join(sb.work, ".quickmenu.conf"), "w") as fh:
            fh.write("Project build = echo conf-build\n")
        r = zsh(sb, "quickmenu --list", QUICKMENU_LOCAL="0")
        check("QUICKMENU_LOCAL=0 disables project menus",
              "Project build" not in r.stdout, r.stdout + r.stderr)
    finally:
        sb.close()

    # ------------------------------------------------------------- locale
    print("\nlocale fallback")
    sb = Sandbox(configs={"menu.conf": "Say hi = echo hi\nSay bye = echo bye\n"})
    out = os.path.join(sb.dir, "out.txt")
    try:
        glyphs = '_qm_glyphs; print -r -- "${_QM_G_PROMPT}|${_QM_G_CARET}|${_QM_G_ELLIPSIS}"'
        r = zsh(sb, glyphs, LANG="C", LC_ALL="C")
        check("non-UTF-8 locale falls back to ASCII glyphs",
              r.stdout.strip() == "> |_|..", r.stdout + r.stderr)

        r = zsh(sb, glyphs, LANG="en_US.UTF-8", LC_ALL="en_US.UTF-8")
        check("UTF-8 locale keeps the nicer glyphs",
              "\u276f" in r.stdout and "\u2026" in r.stdout, r.stdout + r.stderr)

        rc, screen = zsh_pty(sb, f"quickmenu --print > {out!r}", [ENTER],
                             LANG="C", LC_ALL="C")
        with open(out) as fh:
            picked = fh.read().strip()
        check("menu is usable in a non-UTF-8 locale",
              picked == "echo hi" and "1 Say hi" in screen, picked + "\n" + screen[-400:])
    finally:
        sb.close()

    # ------------------------------------------------- degraded terminals
    print("\ndegraded terminals")
    sb = Sandbox(configs={"menu.conf": "Say hi = echo hi\nSay bye = echo bye\n"})
    out = os.path.join(sb.dir, "out.txt")
    try:
        # A terminal we cannot put into raw mode must fall back to the numbered
        # picker rather than silently waiting for line-buffered input.
        shim = os.path.join(sb.dir, "bin")
        os.makedirs(shim)
        with open(os.path.join(shim, "stty"), "w") as fh:
            fh.write("#!/bin/sh\nexit 1\n")
        os.chmod(os.path.join(shim, "stty"), 0o755)

        rc, screen = zsh_pty(sb, f"quickmenu --print > {out!r}", [b"2\r"],
                             PATH=shim + ":" + os.environ["PATH"])
        with open(out) as fh:
            picked = fh.read().strip()
        check("falls back to the numbered picker when stty fails",
              picked == "echo bye" and "2)" in screen, picked + "\n" + screen[-400:])
    finally:
        sb.close()

    # ------------------------------------------------------------- widget
    print("\nZLE widget (interactive shell, ctrl-g)")
    sb = Sandbox("qm_item 'Say hi' 'print hello-widget'\nqm_item 'Say bye' 'print bye-widget'")
    try:
        with open(os.path.join(sb.home, ".zshrc"), "w") as fh:
            fh.write(
                "PROMPT='PROMPT> '\nRPROMPT=''\n"
                "unsetopt zle_rprompt_indent 2>/dev/null\n"
                f"source {PLUGIN}\n"
            )
        interactive = ["zsh", "-i"]

        rc, screen = zsh_pty(sb, "", [b"\x07", b"\r", b"exit\r"],
                             argv=interactive, settle=1.5)
        check("ctrl-g opens the menu", "quickmenu" in screen, screen[-600:])
        check("widget runs the chosen command", "hello-widget" in screen, screen[-600:])
        check("command lands on the prompt line", "print hello-widget" in screen, screen[-600:])

        rc, screen = zsh_pty(sb, "", [b"\x07", DOWN, b"\r", b"exit\r"],
                             argv=interactive, settle=1.5)
        check("widget honours navigation", "bye-widget" in screen, screen[-600:])

        rc, screen = zsh_pty(sb, "", [b"\x07", TAB, b"\r", b"exit\r"],
                             argv=interactive, settle=1.5)
        check("tab leaves the command editable on the prompt",
              "print hello-widget" in screen and "hello-widget\r\n" in screen, screen[-600:])

        rc, screen = zsh_pty(sb, "", [b"\x07", ESC, b"print back-at-prompt\r", b"exit\r"],
                             argv=interactive, settle=1.5)
        check("esc returns to a usable prompt", "back-at-prompt" in screen, screen[-600:])

        rc, screen = zsh_pty(sb, "", [b"\x07", b"\r", b"print -r -- $history[$((HISTCMD-1))]\r", b"exit\r"],
                             argv=interactive, settle=1.5)
        check("the command is recorded in history", screen.count("print hello-widget") >= 2,
              screen[-600:])
    finally:
        sb.close()

    print(f"\n{len(PASS)} passed, {len(FAIL)} failed")
    if FAIL:
        print("failed: " + ", ".join(FAIL))
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())

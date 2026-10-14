# AGENTS.md

Notes for AI coding agents working on this repo. Humans may prefer
[CONTRIBUTING.md](CONTRIBUTING.md), which covers the same ground more gently.

## What this is

A zsh plugin that shows an interactive menu of frequently used commands. The
user presses `Ctrl-G`, picks an item, and it runs in their current shell.

There is no build step. The plugin is sourced; the tests are a single Python
script that drives the real thing over a pty.

## Commands

```sh
source quickmenu.plugin.zsh          # load it into the current shell
python3 tests/run_tests.py           # the whole suite (~2 min)
QM_TEST_DELAY=2 python3 tests/run_tests.py   # slower machine / CI

# syntax check - note zsh -n only reads its FIRST file argument,
# everything after it becomes $1, $2, ... so loop:
for f in quickmenu.plugin.zsh lib/*.zsh install.sh; do zsh -n "$f" || echo "FAIL $f"; done
```

There is no linter and no formatter. Match the surrounding style.

## Layout

| file | responsibility |
|---|---|
| `quickmenu.plugin.zsh` | entry point: sources `lib/`, defines `qm`, binds the key, registers completion |
| `lib/registry.zsh` | `qm_item`, `qm_git_item`, the in-memory arrays, `_qm_visible` |
| `lib/config.zsh` | `.conf` and `.json` parsers, `--add` writer |
| `lib/core.zsh` | config discovery + caching, the `quickmenu` command, the ZLE widget |
| `lib/picker.zsh` | the picker: native TUI, fzf backend, numbered fallback |
| `lib/resolve.zsh` | `{{placeholder}}` expansion and prompting |
| `menu.default.conf` | template copied to `~/.config/quickmenu/menu.conf` on first run |
| `examples/` | JSON and zsh config examples (not loaded, just docs) |
| `tests/run_tests.py` | the entire suite |

Data flows one way: **config files → `_QM_*` arrays → `_qm_visible` → picker →
`_qm_resolve` → `eval`**. Every format ends up in the same arrays, so a new menu
setting has to be wired into all three loaders.

## Conventions

- `emulate -L zsh` as the first line of every function, and `setopt local_options`
  before changing options.
- `local` every variable. Globals are `typeset -g` and `QUICKMENU_*` (user-facing)
  or `_QM_*` / `_qm_*` (internal).
- Functions a user's config may call are `qm_*`. Everything else is `_qm_*`.
- Messages go to stderr with a `quickmenu: ` prefix. Only `--print` and `--list`
  write to stdout — they're parsed by tests and by users.
- Comment the surprising parts only. If you work around a zsh quirk, say which one.

## Hard rules

1. **No new runtime dependencies.** `jq` is optional and falls back to `python3`;
   `fzf` is opt-in. Anything new must degrade gracefully when missing.
2. **Never break the fallback chain.** The picker must work on a dumb terminal,
   with no tty, and when `stty` can't set raw mode. `_qm_pick_tui` returns `2` to
   mean "I can't do this here" and the dispatcher drops to `_qm_pick_dumb`.
3. **Always restore the terminal.** Raw mode, the cursor, and the drawn region are
   undone in an `always { }` block so a `Ctrl-C` can't leave the user stranded.
4. **Shell-quote every substituted value** in `lib/resolve.zsh` (`${(q)value}`).
   A commit message of `it's a fix; rm -rf /` must stay inert. Only the explicit
   `{{prompt!:...}}` raw form skips this, and that's the user's choice.
5. **Config files are checked before reading** — owned by the user, not
   group/world writable. Don't add a loader that skips `_qm_check_file`.

## zsh traps that have already bitten this code

Each of these was a real bug. Don't reintroduce them.

- **`[[ ]]` does not glob.** `[[ -n $f(#qNf:go+w:) ]]` is always true — the
  qualifier is just text in that context. Use `zmodload zsh/stat` + `zstat`.
- **Leading zeros are not octal** unless `OCTAL_ZEROES` is set. `0022` is decimal
  22. Write `8#22`.
- **`getopts` stops at the first non-option argument.** `qm_item 'L' 'cmd' -y`
  silently dropped the `-y`. `qm_item` now hand-parses so flags work on either
  side of the positionals.
- **`exec {fd}<file 2>/dev/null` redirects the *shell's* stderr permanently.**
  This silently killed every later error message. Scope it:
  `{ exec {fd}<$file } 2>/dev/null`.
- **In raw mode `\n` doesn't return the carriage** (ONLCR is off). Every line the
  picker draws must end with `\r\n`, or the `\e[<n>A` redraw accounting drifts.
- **Word splitting discards empty fields.** The JSON bridge therefore reads one
  field at a time with `read -r -d $'\x1f'` instead of splitting a record, so an
  empty `group` doesn't shift every later field.
- **Nested functions see the caller's locals** (zsh is dynamically scoped).
  `_qm_pick_filter` / `_qm_pick_draw` rely on this, and must be `unfunction`ed in
  the `always` block or they leak into the user's shell.

## Testing

`tests/run_tests.py` has two kinds of check:

- **Subprocess tests** — `zsh(sandbox, script)` runs a snippet with a throwaway
  `HOME` and asserts on stdout/stderr/exit code.
- **pty tests** — `zsh_pty(sandbox, script, keys)` allocates a pty, makes it the
  controlling terminal (`setsid` then `TIOCSCTTY`, otherwise `/dev/tty` fails),
  feeds raw keystrokes and returns everything the terminal saw.

Rules that keep the suite honest:

- **Assert on the result, not the screen.** pty tests write the chosen command to
  a file (`quickmenu --print > out.txt`) and assert on that. Screen text is only
  for checking that something rendered at all — never parse ANSI.
- Use `Sandbox(configs={...})` for `.conf`/`.json` and `Sandbox(menu=...)` for the
  zsh format. Each sandbox gets its own `HOME`, so tests can't see each other.
- Timings are multiplied by `QM_TEST_DELAY`. Never hardcode a `sleep`.
- Tests must pass on Linux and macOS, with and without `jq`, and under `LANG=C`.
  CI runs all of those.

## Adding a menu setting end to end

Say you're adding `.icon`. You need to touch:

1. `lib/registry.zsh` — a new `_QM_ICON` array, a flag in `qm_item`, and the
   matching `_qm_vis_*` entry in `_qm_visible`.
2. `lib/config.zsh` — the `.conf` modifier `case` (both the item and section
   branches), the `jq` program **and** the `python3` fallback, and the field
   order in `_qm_add_parsed`. The two JSON backends must emit identical streams.
3. `lib/picker.zsh` — rendering, if it's visible.
4. `menu.default.conf` and `README.md` — document it.
5. `tests/run_tests.py` — a `.conf` case, a `.json` case for *both* backends, and
   a pty case if it changes what's on screen.
6. `CHANGELOG.md` under `Unreleased`.

Forgetting the python3 JSON branch is the usual mistake; it only shows up on a
machine without `jq`. The suite guards this by running both backends
(`QUICKMENU_JSON=jq` / `QUICKMENU_JSON=python3`) and asserting their field
streams are byte-identical — so add your field to both or that check fails.

**Never select a backend by editing `PATH` in a test.** Stripping every
directory that contains `jq` also strips `/usr/bin`, which removes `git` on a
Linux runner and silently hides every item with a git condition. Use
`QUICKMENU_JSON` instead.

## Before you finish

```sh
python3 tests/run_tests.py          # must be 100% green
for f in quickmenu.plugin.zsh lib/*.zsh install.sh; do zsh -n "$f" || echo "FAIL $f"; done
```

Then check: does it still work with no config at all, in a non-git directory, and
on a terminal that isn't UTF-8? Those three cases break more often than the happy
path.

# Contributing

Thanks for taking a look. Bug reports, menu ideas and patches are all welcome.

> Working with an AI coding agent? Point it at [AGENTS.md](AGENTS.md) — same
> information, plus the zsh traps this codebase has already fallen into.

## Getting set up

```sh
git clone https://github.com/prashant1207/zsh-quickmenu
cd zsh-quickmenu
source quickmenu.plugin.zsh      # try it in your current shell
python3 tests/run_tests.py       # run the suite
```

You need `zsh` 5.3+, `git` and `python3`. `jq` is optional — the JSON loader
falls back to `python3`.

## Running the tests

```sh
python3 tests/run_tests.py
```

The suite spins up throwaway `HOME` directories and drives the real menu over a
pty with actual keystrokes, so it catches rendering and terminal-state bugs that
unit tests miss. If it's flaky on a slow machine, stretch the timings:

```sh
QM_TEST_DELAY=2 python3 tests/run_tests.py
```

**Every change needs a test.** Adding a menu setting means adding a case to the
`.conf`/`.json` sections; changing the picker means adding a pty test with the
keystrokes it affects.

## Project layout

| path | what's in it |
|---|---|
| `quickmenu.plugin.zsh` | entry point: sources `lib/`, defines `qm`, binds the key |
| `lib/registry.zsh` | `qm_item` and the in-memory item list |
| `lib/config.zsh` | `.conf` and `.json` parsers, `--add` writer |
| `lib/core.zsh` | config discovery, the `quickmenu` command, the ZLE widget |
| `lib/picker.zsh` | the interactive picker (native TUI, fzf, numbered fallback) |
| `lib/resolve.zsh` | `{{placeholder}}` expansion |
| `menu.default.conf` | the template new users get |
| `examples/` | JSON and zsh config examples |

## Style

- Plain zsh, no new runtime dependencies. If something needs an external tool,
  it has to degrade gracefully when the tool isn't there.
- `emulate -L zsh` at the top of every function, and `local` everything.
- Comment the surprising bits only. zsh has a lot of sharp edges
  (`exec {fd}<f 2>/dev/null` silences the *shell's* stderr; `0022` isn't octal
  unless `OCTAL_ZEROES` is set) — when you work around one, say so in a comment.
- Internal helpers are prefixed `_qm_`; anything a user's config calls is `qm_*`.

## Pull requests

1. Open an issue first for anything bigger than a bug fix.
2. Keep the diff focused; unrelated cleanups in their own PR.
3. Make sure `python3 tests/run_tests.py` passes on macOS or Linux — CI runs both.
4. Update `README.md` and `CHANGELOG.md` when behaviour changes.

## Reporting bugs

Include your `zsh --version`, your OS, the relevant part of your menu config, and
the output of `qm --config`. If it's a display problem, a screenshot of the menu
helps a lot.

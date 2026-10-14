# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-10-14

First public release.

### Added

- Interactive launcher menu for zsh, bound to `Ctrl-G` by default.
- Dependency-free TUI picker: arrow keys / `Ctrl-N` / `Ctrl-P`, `1`-`9` and `0`
  to jump to a visible row, type-to-filter with label matches ranked first,
  `Enter` to run, `Tab` to put the command on the prompt, `Esc` to cancel.
- Optional `fzf` backend (`QUICKMENU_USE_FZF=1`) and a numbered fallback for
  dumb terminals and non-interactive use.
- Three config formats, all loaded when present:
  - `menu.conf` — `Label = command` with `[section]` groups and `.if`,
    `.desc`, `.group`, `.confirm`, `.edit` settings.
  - `menu.json` — read with `jq`, falling back to `python3`.
  - `menu.zsh` — `qm_item` / `qm_git_item` for menus built at runtime.
- Extra snippets from `menu.d/*.{conf,json,zsh}`.
- Project-local menus: `.quickmenu.{conf,json,zsh}`, searched upwards from
  `$PWD`, skipped when not owned by the user or writable by others.
- Placeholders resolved at launch time: `{{prompt:Label=default}}`,
  `{{pick:command}}`, `{{file:glob}}`, `{{dir}}`, `{{env:NAME}}`. Values are
  shell-quoted unless the keyword ends in `!`.
- Conditional items, confirmations and edit-only items.
- CLI: `qm [query]`, `--list`, `--print`, `--index`, `--add`, `--edit`,
  `--config`, `--reload`, `--help`, plus tab completion for item labels.
- Chosen commands are added to shell history and run in the calling shell, so
  `cd` and `source` work.
- ASCII fallbacks for the menu glyphs when the locale isn't UTF-8, and an
  automatic drop to the numbered picker on terminals that can't be put into
  raw mode.

[Unreleased]: https://github.com/prashant1207/zsh-quickmenu/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/prashant1207/zsh-quickmenu/releases/tag/v0.1.0

# ccmole

Interactive cleanup tool and privacy switchboard for Claude Code — a single
shell script, driven by the arrow keys.

Claude Code stores its data under `~/.claude` and only cleans up so much of it.
`ccmole` shows what is taking up the space and makes the built-in commands
reachable without having to remember paths and session IDs.

```
╭─ ccmole 2.3.2 ───────────────────────────────────────╮
│  ~/.claude   250 MB   2829 files                     │
╰──────────────────────────────────────────────────────╯

   projects         ██████████████████     234 MB
   file-history     █·················      13 MB

  ▸ p  clean up projects          13 found
    j  junk & caches              6 areas
    d  privacy                    7 of 10 active
    k  view backups
    r  rescan
    X  full reset                 purge --all
    q  quit
```

## Installation

```sh
git clone <repo> ccmole
cd ccmole
./ccmole.sh --selftest    # checks the platform assumptions, deletes nothing
./ccmole.sh --install     # copies to ~/.local/bin/ccmole
```

`--install` detects the shell in use and suggests `fish_add_path` instead of an
`export` line for fish, should `~/.local/bin` not be on the `PATH`.

## Keys

| Key | Effect |
| --- | --- |
| `↑` `↓` or `k` `j` | move (wraps around at the ends) |
| `Space` | select and move down one row |
| `Enter` | select / open a menu entry |
| `PgUp` `PgDn`, `g` `G` | by page, start / end |
| `q` | back, quit in the main menu |

In the main menu the letters double as direct shortcuts. Lists scroll with a
remainder indicator (`↓ 6 more`) when they do not fit the terminal; the visible
height is measured again on every frame.

## The screens

### Projects

Every project sorted by size, with age, an orphan marker (the original folder no
longer exists), the number of memory files and an `active` hint for changes made
within the last 15 minutes. Deletion comes in two levels:

| Key | deletes | keeps |
| --- | --- | --- |
| `t` | `.jsonl`, `tool-results/`, `subagents/`, `workflows/`, `file-history/<id>/`, `tasks/<id>/` | `memory/` and the entry in `~/.claude.json` |
| `c` | everything, through `claude project purge` | none of it |

The difference matters: `claude project purge` always takes `memory/` along and
removes the project entry including its trust status and MCP server
configuration. Level `t` only deletes what hangs off the sessions.

Preview with `T` or `d`, with a preceding backup `B` or `b`.

### Junk & caches

Areas `claude project purge` does not cover: `jobs/*/tmp`, `debug/`,
`telemetry/`, `paste-cache/`, `shell-snapshots/`, `cache/`, `statsig/`,
`file-history/` and `backups/`. Every entry carries a risk level; `s` selects
everything rated "low".

For job directories `state.json` is read: only finished jobs (`"state": "done"`)
count as harmless, running ones and those without a status file are rated
"high".

### Privacy

Shows the current state from `settings.json` as check marks, `Space` toggles the
target state, `w` writes the difference. A `!` marks entries with side effects;
`S` selects all the others.

Covered are, among others, `DISABLE_ERROR_REPORTING`, `DISABLE_FEEDBACK_COMMAND`,
`DISABLE_TELEMETRY`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`,
`feedbackSurveyRate`, `cleanupPeriodDays` (value adjustable with `←`/`→`),
`disableClaudeAiConnectors`, `enableArtifact`, `remoteControlAtStartup` and
`skipWebFetchPreflight`.

The assessment is context aware: both telemetry switches also silence the
feature flag evaluation that remote control depends on. When
`remoteControlAtStartup` is not set to `true`, that warning is dropped.

A diff and a confirmation prompt come before writing. The old file moves to
`~/.claude-backups/settings-<timestamp>.json`, the write itself goes through a
temporary file and is atomic; every unrelated key stays untouched.

## Safety

* Every deletion passes a path check: anything outside the Claude directory, the
  directory itself, `..` and symlinks pointing outward are refused.
* Protected names are never deleted: `settings.json`, `settings.local.json`,
  `CLAUDE.md`, `credentials.json`, `skills/`, `commands/`, `agents/`, `plugins/`,
  `ide/`, `hooks/`, `memory/`, `rules/`, `workflows/`, `keybindings.json`.
* Deletions require typing `DELETE`, the full reset `DELETE ALL`.
* `b` or `B` writes a `tar.gz` to `~/.claude-backups` before deleting.
* `--dry-run` and the preview keys change nothing.

## Invocations

```
ccmole              start interactively
ccmole --status     print an overview and exit
ccmole --dry-run    show the deletion plan for all projects
ccmole --install    install to ~/.local/bin/ccmole
ccmole --uninstall  remove that copy again, backups optional
ccmole --selftest   check the platform assumptions
ccmole --version    version
ccmole --help       help
```

`--uninstall` removes exactly one file, the copy in `~/.local/bin`. It then
names what it does not touch on its own: the backups in `~/.claude-backups` and
the switches written to `settings.json`, which are Claude Code settings by then
rather than ccmole state. The backups can be removed in the same run, but only
after typing `DELETE`.

## Environment variables

| Variable | Meaning |
| --- | --- |
| `CLAUDE_CONFIG_DIR` | Claude directory (default: `~/.claude`) |
| `CCMOLE_BACKUP_DIR` | where backups are stored (default: `~/.claude-backups`) |
| `CCMOLE_NO_ALTSCREEN` | disable the alternate screen buffer |
| `NO_COLOR` | disable colors |

## Requirements

bash 3.2 or newer, POSIX coreutils and the `claude` CLI from version 2.1.124
(for `claude project purge`). `python3` is required for the privacy screen and
otherwise only used when present.

Runs on macOS and Linux. Platform differences are detected at startup rather
than through `uname`: `stat -f` against `stat -c`, `find -printf` against
`find -exec stat`. Without a UTF-8 locale the output falls back to ASCII.
`./ccmole.sh --selftest` checks all of this on the system at hand.

## Status

Personal project, published in case it is useful. There is no support and no
roadmap, and the issue tracker is closed. Fork it if you need it to work
differently.

## License

[MIT](LICENSE)

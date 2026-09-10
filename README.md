# hop

[![test](https://github.com/etdebruin/hop/actions/workflows/test.yml/badge.svg)](https://github.com/etdebruin/hop/actions/workflows/test.yml)

Jump to any directory by name, from anywhere.

```console
$ pwd
~/Code/dotfiles/chrome/themes

$ hop aixcto
~/Code/aixcto
```

No database to warm up, no "visit it once so I learn it" — `hop` searches your
project roots live, every time. A repo you cloned thirty seconds ago and have
never `cd`'d into is just as reachable as the one you live in.

## Why not `z` / `zoxide` / `autojump`?

Those are *frecency* tools: they rank the directories you already visit. That's
a genuinely different job, and they're very good at it. The gap is the first
visit — a freshly cloned repo, a directory a teammate told you about, anything
you've never opened — where a frecency database has nothing to offer.

`hop` searches the filesystem instead, so:

- **it finds directories you've never been to**, which is the case that sends
  you back to `find` or a file manager
- **there's no state**: nothing to sync between machines, nothing to import,
  nothing to go stale, no `hop --add`
- **it's about as fast as it can be.** A depth-4 scan of a 4,276-directory
  tree takes **~0.1s** — imperceptible, and it re-runs on every single call so
  what you see is always the truth on disk

`cdpath` — the zsh built-in — covers a slice of this with zero install, but
only matches *direct children* of the paths you list, so every nesting level
needs its own entry. `hop` handles arbitrary nesting and ambiguity. The two
compose fine; keep `cdpath` for tab-completing top-level names if you like it.

## Install

Clone it, then run the installer:

```sh
git clone https://github.com/etdebruin/hop.git ~/.hop
sh ~/.hop/install.sh
```

That appends a small block to your `~/.zshrc` (or `~/.bashrc`) and is
idempotent — re-running rewrites the block instead of stacking a second copy.

Or wire it up yourself:

```sh
. /path/to/hop/hop.sh

# zsh tab-completion. Register it explicitly rather than relying on compinit:
# on macOS, compinit has already run (from /etc/zshrc) by the time your own rc
# is sourced, so a late fpath addition alone is never picked up.
if [ -n "${ZSH_VERSION:-}" ]; then
  fpath=(/path/to/hop/completions $fpath)
  autoload -Uz _hop
  whence compdef >/dev/null 2>&1 && compdef _hop hop
fi
```

`hop` must be **sourced**, not executed. Changing your working directory is
something only the current shell can do, so it ships as a shell function.

Requires zsh or bash, plus `find`, `awk` and `sort` — all of which you already
have. No compiler, no runtime, no daemon.

## Usage

```console
$ hop aixcto                # exact name, anywhere under your roots
$ hop dotf                  # prefix match
$ hop andbox                # substring match
$ hop AIXCTO                # case-insensitive
$ hop                       # no argument: browse everything, type to filter
```

### Browsing

Run `hop` with no argument and you get every directory under your roots,
narrowing as you type:

```console
$ hop
   ~/Code/aixcto
❯  ~/Code/dotfiles
   ~/Code/su/backend
   ~/Code/vega/cto-compass
hop> dot  (2/4276)
```

Anything printable filters, `↑`/`↓` move, `Enter` jumps, `^U` clears the
filter, `Esc` or `^C` back out. Filtering is re-ranked on every keystroke and
takes about **15ms** over 4,276 directories, so it keeps up with typing.

There is no select-by-number here — with thousands of rows a number means
nothing, and the filter is the point. `hop --list` with no name prints the same
set non-interactively.

When a name is ambiguous, you get a picker. Arrow down to the one you want and
press Enter — or type its number, which works exactly as it always did:

```console
$ hop ctocompass
❯  1) ~/Code/CTO/ctocompass
   2) ~/Code/ctoapps/ctocompass
   3) ~/Code/vega/cto-compass/cmd/ctocompass
hop>   (1-3, arrows)
```

| key | |
|---|---|
| `↑` `↓` — or `k` `j`, or `^P` `^N` | move the highlight (wraps at both ends) |
| `Enter` | take the highlighted row |
| digits, then `Enter` | select by number |
| `Esc`, `q`, `^C` | cancel |

The menu erases itself on the way out, so your scrollback stays clean. Unlike
browsing, typing a letter here does nothing — hence the hint, which names the
numbers that are live.

Nesting is not ambiguity. A match that sits inside another match *under the
same name* is that name seen from further in, not a second destination, so the
outer one wins and there is no prompt:

```console
$ hop conversation                       # not asked to choose between
~/Code/conversation                      #   ~/Code/conversation and
                                         #   ~/Code/conversation/app/api/conversation
```

Only under the same name, though: a differently-named directory that merely
happens to live inside another match is a different place, and is still
offered. `hop --list` and browsing show everything either way.

Or settle it in one shot with a path fragment:

```console
$ hop CTO/ctocompass
~/Code/CTO/ctocompass
```

If [`fzf`](https://github.com/junegunn/fzf) is installed, the picker uses it
automatically; `HOP_PICKER=arrow` forces the built-in one instead. Where there
is no terminal to drive — a pipe, a script, a `TERM=dumb` session — it degrades
to a plain numbered prompt that reads a number from stdin, so `hop` stays
scriptable.

### Options

| | |
|---|---|
| `-l`, `--list` | print every match instead of jumping |
| `-d`, `--depth N` | how deep to descend, just for this call |
| `--roots` | print the directories `hop` searches |
| `-h`, `--help` | help |
| `-V`, `--version` | version |

## How matching works

Candidates are graded into tiers, and **only the best non-empty tier is
returned** — so an exact name never has to compete with a coincidental
substring. `hop api` lands on `api`, not on a menu that also offers
`apiserver`.

1. exact name
2. exact name, ignoring case
3. name starts with the query
4. name contains the query

A query containing `/` is matched against the *tail of the path* instead of the
name, at the same tiers. Within a tier, shallower paths come first, then
alphabetical.

## Configuration

All optional, all environment variables:

| variable | default | |
|---|---|---|
| `HOP_ROOTS` | `~/Code` if it exists, else `$HOME` | colon-separated dirs to search; a leading `~/` is expanded |
| `HOP_DEPTH` | `4` | how deep to descend |
| `HOP_EXCLUDES` | see below | colon-separated directory *names* to never descend into |
| `HOP_PICKER` | `auto` | `auto`, `arrow`, `numbered`, or `fzf` |
| `HOP_QUIET` | unset | set to `1` to not print the destination |
| `HOP_CACHE_TTL` | `30` | seconds to reuse the tab-completion index |

```sh
export HOP_ROOTS="$HOME/Code:$HOME/work:$HOME/.config"
export HOP_DEPTH=5
```

`HOP_EXCLUDES` defaults to the usual regenerable noise — `.git`, `node_modules`,
`.venv`, `target`, `dist`, `build`, `vendor`, `Pods`, `.dart_tool`,
`.terraform`, `DerivedData`, `__pycache__` and friends. Pruning those is most of
why the scan is fast; setting `HOP_EXCLUDES=""` searches everything and will be
noticeably slower on a real tree.

The search itself is **never cached** — only the tab-completion index is, for
`HOP_CACHE_TTL` seconds, because completion runs far more often than you jump.

## Tests

```sh
bash test/test-hop.sh
```

140 assertions. Every behavioural assertion runs under **both bash and zsh**,
against a throwaway fixture tree — match tiering, ambiguity and the picker,
nested same-name matches, depth limits, pruning, multiple roots, symlinked
roots, `~` expansion, names with spaces, exit codes, and the installer's
idempotence.

The pickers only engage on a real terminal, so they are tested through one:
`test/pty-pick.zsh` spawns `hop` under a pty, sends actual keystrokes, and
checks where the shell ended up — covering both the disambiguation picker and
the browser, including filtering, backspace and every way out.

Landing on the right directory isn't proof the screen looked right, though, so
the redraw is tested by rendering it: `test/screen.awk` is a small terminal
emulator that replays the raw pty stream onto a virtual screen, and the tests
assert on what would actually be visible — one prompt line, no stale rows, no
climbing over whatever was already on screen. A redraw that steps back up one
line too many looks entirely reasonable in the byte stream while smearing
prompts up the terminal, and that is exactly the bug it exists to catch.

All of these skip automatically if `zsh/zpty` isn't available.

## License

MIT

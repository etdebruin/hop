#!/usr/bin/env bash
# Tests for hop. Run: bash test/test-hop.sh
#
# Every assertion runs in every available shell (bash and zsh), because hop
# ships as a sourced function and must behave identically in both.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOP_SH="$ROOT/hop.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL [%s] %s\n       want: %s\n       got:  %s\n' "$SH" "$1" "$2" "$3"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1" "$2" "$3"; fi; }
has() { case "$3" in *"$2"*) ok ;; *) bad "$1" "contains <$2>" "$3" ;; esac; }
hasnt() { case "$3" in *"$2"*) bad "$1" "does NOT contain <$2>" "$3" ;; *) ok ;; esac; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---- fixture tree -----------------------------------------------------------
mkdir -p \
  "$TMP/Code/aixcto" \
  "$TMP/Code/dotfiles" \
  "$TMP/Code/api" \
  "$TMP/Code/apiserver" \
  "$TMP/Code/CTO/ctocompass" \
  "$TMP/Code/ctoapps/ctocompass" \
  "$TMP/Code/su/backend" \
  "$TMP/Code/conversation/app/routes/conversation" \
  "$TMP/Code/zeta/zetaside" \
  "$TMP/Code/everydev" \
  "$TMP/Code/dotfiles/chrome/themes/everydev" \
  "$TMP/Code/nest/widget" \
  "$TMP/Other/deep/root/widget" \
  "$TMP/Code/deep/a/b/c/needle" \
  "$TMP/Code/proj/node_modules/evil" \
  "$TMP/Code/proj/.git/hooks" \
  "$TMP/Code/mixed/UPPER" \
  "$TMP/Code/spaced/two words" \
  "$TMP/Other/sandbox" \
  "$TMP/elsewhere"
mkdir -p "$TMP/target/portal"
ln -sfn "$TMP/target" "$TMP/Code/linked"

cat > "$TMP/preamble.sh" <<PRE
export HOP_ROOTS="$TMP/Code"
export HOME="$TMP"
. "$HOP_SH"
cd "$TMP/elsewhere"
PRE

# run <snippet> [stdin]   -- @TMP@ in the snippet expands to the fixture root.
# Returns stdout+stderr merged; sets RC to the snippet's exit status.
run() {
  local snip input
  snip="$(printf '%s\n' "$1" | sed "s|@TMP@|$TMP|g")"
  input="${2-}"
  printf '. "%s"\n%s\n' "$TMP/preamble.sh" "$snip" > "$TMP/t.sh"
  local out
  if [ -n "$input" ]; then
    out="$(printf '%s\n' "$input" | "$SH" "$TMP/t.sh" 2>&1)"
  else
    out="$("$SH" "$TMP/t.sh" </dev/null 2>&1)"
  fi
  RC=$?
  printf '%s' "$out"
}

SHELLS=""
for s in bash zsh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done

for SH in $SHELLS; do
  printf 'shell: %s\n' "$SH"

  # -- resolution ------------------------------------------------------------
  eq "exact match cds there" \
    "$TMP/Code/aixcto" "$(run 'hop aixcto >/dev/null 2>&1; printf %s "$PWD"')"

  eq "exact match beats prefix match" \
    "$TMP/Code/api" "$(run 'hop api >/dev/null 2>&1; printf %s "$PWD"')"

  eq "prefix match when no exact match" \
    "$TMP/Code/dotfiles" "$(run 'hop dotf >/dev/null 2>&1; printf %s "$PWD"')"

  eq "substring match when no prefix match" \
    "$TMP/Other/sandbox" "$(run 'HOP_ROOTS="@TMP@/Code:@TMP@/Other"; hop andbox >/dev/null 2>&1; printf %s "$PWD"')"

  eq "case-insensitive match" \
    "$TMP/Code/mixed/UPPER" "$(run 'hop upper >/dev/null 2>&1; printf %s "$PWD"')"

  eq "path-suffix query disambiguates" \
    "$TMP/Code/CTO/ctocompass" "$(run 'hop CTO/ctocompass >/dev/null 2>&1; printf %s "$PWD"')"

  eq "directory name containing a space" \
    "$TMP/Code/spaced/two words" "$(run 'hop "two words" >/dev/null 2>&1; printf %s "$PWD"')"

  # -- misses ----------------------------------------------------------------
  out="$(run 'hop zzznope; printf "|%s" "$PWD"')"
  has "no match reports on stderr" "no directory matching" "$out"
  has "no match leaves cwd alone" "|$TMP/elsewhere" "$out"
  eq  "no match exits non-zero" "1" "$(run 'hop zzznope >/dev/null 2>&1; printf %s "$?"')"

  # -- HOP_ON_MISS: a miss can fetch the directory (e.g. clone it) ----------
  # The hook gets the query as $1 and prints the directory it produced. Names
  # carry the shell, since the fixture tree is shared and a directory made in
  # the bash pass would otherwise be a plain match for the zsh one.
  miss_hook='fetch() { mkdir -p "@TMP@/Code/$1" && echo "made $1" >&2 && printf "%s\n" "@TMP@/Code/$1"; }
HOP_ON_MISS=fetch'
  eq "on-miss hook's directory is where hop lands" \
    "$TMP/Code/fresh1-$SH" "$(run "$miss_hook
hop fresh1-$SH >/dev/null 2>&1; printf %s \"\$PWD\"")"
  eq "on-miss success exits 0" "0" "$(run "$miss_hook
hop fresh2-$SH >/dev/null 2>&1; printf %s \"\$?\"")"
  has "hook's own chatter still reaches the user" "made fresh3-$SH" "$(run "$miss_hook
hop fresh3-$SH 2>&1 >/dev/null")"
  eq "hook is not consulted when something matches" \
    "$TMP/Code/aixcto|" "$(run 'HOP_ON_MISS="echo CALLED >&2; false"
hop aixcto 2>/dev/null; printf "%s|" "$PWD"; hop aixcto 2>&1 | grep CALLED')"
  out="$(run 'HOP_ON_MISS=false
hop zzznope; printf "|%s|%s" "$?" "$PWD"')"
  has "failing hook: still reports the miss" "no directory matching" "$out"
  has "failing hook: exits 1, cwd untouched" "|1|$TMP/elsewhere" "$out"
  eq "hook printing a non-directory is ignored" "1|$TMP/elsewhere" \
    "$(run 'HOP_ON_MISS="echo /nonexistent/zz; :"
hop zzznope >/dev/null 2>&1; printf "%s|%s" "$?" "$PWD"')"
  eq "--list never runs the hook" "" \
    "$(run 'HOP_ON_MISS="echo CALLED"
hop --list zzznope 2>/dev/null')"
  eq "query with spaces reaches the hook as one argument" \
    "$TMP/Code/two new-$SH" "$(run "$miss_hook
hop \"two new-$SH\" >/dev/null 2>&1; printf %s \"\$PWD\"")"

  # -- pruning and depth -----------------------------------------------------
  eq "node_modules is pruned" \
    "1" "$(run 'hop evil >/dev/null 2>&1; printf %s "$?"')"
  eq ".git is pruned" \
    "1" "$(run 'hop hooks >/dev/null 2>&1; printf %s "$?"')"
  eq "beyond max depth is not found" \
    "1" "$(run 'hop needle >/dev/null 2>&1; printf %s "$?"')"
  eq "HOP_DEPTH raises the ceiling" \
    "$TMP/Code/deep/a/b/c/needle" "$(run 'HOP_DEPTH=6; hop needle >/dev/null 2>&1; printf %s "$PWD"')"
  eq "-d flag raises the ceiling" \
    "$TMP/Code/deep/a/b/c/needle" "$(run 'hop -d 6 needle >/dev/null 2>&1; printf %s "$PWD"')"
  eq "-d flag does not leak into later calls" \
    "1" "$(run 'hop -d 6 needle >/dev/null 2>&1; cd "@TMP@/elsewhere"; hop needle >/dev/null 2>&1; printf %s "$?"')"
  eq "HOP_EXCLUDES is honoured" \
    "$TMP/Code/ctoapps/ctocompass" "$(run 'HOP_EXCLUDES="CTO"; hop ctocompass >/dev/null 2>&1; printf %s "$PWD"')"

  # -- multiple roots --------------------------------------------------------
  eq "searches every root" \
    "$TMP/Other/sandbox" "$(run 'HOP_ROOTS="@TMP@/Code:@TMP@/Other"; hop sandbox >/dev/null 2>&1; printf %s "$PWD"')"
  out="$(run 'HOP_ROOTS="@TMP@/Code:@TMP@/nope"; hop --roots')"
  hasnt "--roots drops roots that do not exist" "/nope" "$out"
  has  "--roots lists real roots" "$TMP/Code" "$out"
  eq "a leading ~ in HOP_ROOTS is expanded" \
    "$TMP/Code/aixcto" "$(run 'HOP_ROOTS="~/Code"; hop aixcto >/dev/null 2>&1; printf %s "$PWD"')"
  eq "symlinked directories are followed" \
    "$TMP/Code/linked/portal" "$(run 'hop portal >/dev/null 2>&1; printf %s "$PWD"')"

  # -- ambiguity -------------------------------------------------------------
  out="$(run 'hop --list ctocompass')"
  eq "--list prints every match, shallowest first" \
    "$TMP/Code/CTO/ctocompass
$TMP/Code/ctoapps/ctocompass" "$out"
  # Byte order, so uppercase names sort first -- deliberate, for determinism.
  eq "--list with no name enumerates everything, shallowest first" \
    "$TMP/Code/CTO" "$(run 'hop --list | head -1')"
  eq "--list with no name includes deeper entries too" \
    "1" "$(run 'hop --list | grep -c CTO/ctocompass')"

  eq "--list does not cd" \
    "$TMP/Code/CTO/ctocompass|$TMP/elsewhere" "$(run 'hop --list ctocompass | head -1 | tr -d "\n"; printf "|%s" "$PWD"')"

  eq "picker choice is honoured" \
    "$TMP/Code/ctoapps/ctocompass" "$(run 'hop ctocompass >/dev/null 2>&1; printf %s "$PWD"' '2')"
  eq "picker respects choice 1" \
    "$TMP/Code/CTO/ctocompass" "$(run 'hop ctocompass >/dev/null 2>&1; printf %s "$PWD"' '1')"
  out="$(run 'hop ctocompass; printf "|%s" "$PWD"' '9')"
  has "out-of-range choice is refused" "no such choice" "$out"
  has "out-of-range choice leaves cwd alone" "|$TMP/elsewhere" "$out"
  eq "cancelling the picker leaves cwd alone" \
    "$TMP/elsewhere" "$(run 'hop ctocompass >/dev/null 2>&1; printf %s "$PWD"')"
  has "picker menu is numbered" ") $TMP/Code/CTO/ctocompass" \
    "$(run 'HOP_PICKER=numbered; hop ctocompass >/dev/null' '1')"
  has "numbered picker names the range it wants" "1-2" \
    "$(run 'HOP_PICKER=numbered; hop ctocompass >/dev/null' '1')"

  # -- nesting ---------------------------------------------------------------
  # A match that lives inside another match under the same name is that match,
  # seen from further in; asking which one you meant is a question with one
  # answer. No stdin here, so a picker would cancel and leave $PWD alone.
  eq "a same-name match nested inside another does not force a choice" \
    "$TMP/Code/conversation" "$(run 'hop conversation >/dev/null 2>&1; printf %s "$PWD"')"
  eq "collapsing the nest still prints the destination" \
    "0" "$(run 'hop conversation >/dev/null 2>&1; printf %s "$?"')"
  eq "--list still shows every nested match" "2" \
    "$(run 'hop --list conversation | grep -c conversation')"
  eq "browsing still sees every nested match" "1" \
    "$(run 'hop --list | grep -c "conversation/app/routes/conversation"')"

  # -- depth ------------------------------------------------------------------
  # Two directories of the same name at different depths are not really a
  # question either: the one nearer the root is the project, the deep one is a
  # copy, a theme, a fixture. Shallowest wins; -a asks anyway.
  eq "the shallowest match wins without asking" \
    "$TMP/Code/everydev" "$(run 'hop everydev >/dev/null 2>&1; printf %s "$PWD"')"
  eq "collapsing by depth still prints the destination" \
    "0" "$(run 'hop everydev >/dev/null 2>&1; printf %s "$?"')"
  eq "-a offers the deeper matches too" \
    "$TMP/Code/dotfiles/chrome/themes/everydev" \
    "$(run 'hop -a everydev >/dev/null 2>&1; printf %s "$PWD"' '2')"
  eq "--all is the long spelling" \
    "$TMP/Code/dotfiles/chrome/themes/everydev" \
    "$(run 'hop --all everydev >/dev/null 2>&1; printf %s "$PWD"' '2')"
  eq "-a still collapses a same-name nest" \
    "$TMP/Code/conversation" "$(run 'hop -a conversation >/dev/null 2>&1; printf %s "$PWD"')"
  eq "--list shows the deeper matches regardless" "2" \
    "$(run 'hop --list everydev | grep -c everydev')"
  # Matches at the same depth are a real question, and still get asked.
  eq "equally shallow matches still ask" \
    "$TMP/Code/ctoapps/ctocompass" "$(run 'hop ctocompass >/dev/null 2>&1; printf %s "$PWD"' '2')"
  # Depth is counted from each root, not from /: a match one level under a
  # deeply-nested root is shallower than one two levels under a short root.
  eq "depth is measured from the root it was found under" \
    "$TMP/Other/deep/root/widget" \
    "$(run 'HOP_ROOTS="@TMP@/Code:@TMP@/Other/deep/root"; hop widget >/dev/null 2>&1; printf %s "$PWD"')"
  # Different names at different depths collapse the same way -- the rule is
  # about depth, not about the name.
  eq "a differently-named deeper match is dropped too" \
    "$TMP/Code/zeta" "$(run 'hop zet >/dev/null 2>&1; printf %s "$PWD"')"
  eq "-a offers the differently-named deeper match" \
    "$TMP/Code/zeta/zetaside" "$(run 'hop -a zet >/dev/null 2>&1; printf %s "$PWD"' '2')"

  # -- output ----------------------------------------------------------------
  has "prints the destination, ~-abbreviated" "~/Code/aixcto" \
    "$(run 'hop aixcto')"
  eq "HOP_QUIET silences the destination line" \
    "" "$(run 'HOP_QUIET=1; hop aixcto')"
  eq "destination line goes to stderr, not stdout" \
    "" "$(run 'hop aixcto 2>/dev/null')"

  # -- flags -----------------------------------------------------------------
  has "--help prints usage" "Usage: hop" "$(run 'hop --help')"
  eq  "--help exits 0" "0" "$(run 'hop --help >/dev/null; printf %s "$?"')"
  has "usage credits the author" "etienne@everydev.com" "$(run 'hop --help')"
  has "usage points at the browser" "--browse" "$(run 'hop --help')"
  has "usage documents --all" "--all" "$(run 'hop --help')"
  # Bare `hop` is a question, not a destination: it says what hop can do and
  # leaves you where you are.
  has "bare hop prints usage" "Usage: hop" "$(run 'hop')"
  eq  "bare hop exits 0" "0" "$(run 'hop >/dev/null 2>&1; printf %s "$?"')"
  eq  "bare hop does not cd" \
    "$TMP/elsewhere" "$(run 'hop >/dev/null 2>&1; printf %s "$PWD"')"
  eq  "--browse without a tty falls back to the first root" \
    "$TMP/Code" "$(run 'hop --browse >/dev/null 2>&1; printf %s "$PWD"')"
  eq  "-i is --browse" \
    "$TMP/Code" "$(run 'hop -i >/dev/null 2>&1; printf %s "$PWD"')"
  has "--version prints a version" "hop 0." "$(run 'hop --version')"
  eq  "unknown option exits 2" "2" "$(run 'hop --bogus >/dev/null 2>&1; printf %s "$?"')"
  eq  "-- ends option parsing" \
    "$TMP/Code/aixcto" "$(run 'hop -- aixcto >/dev/null 2>&1; printf %s "$PWD"')"

  # -- completion index ------------------------------------------------------
  out="$(run 'export XDG_CACHE_HOME="@TMP@/cache"; rm -rf "$XDG_CACHE_HOME"; _hop_candidates')"
  has "candidate index lists basenames" "aixcto" "$out"
  hasnt "candidate index excludes pruned dirs" "evil" "$out"

  eq "candidate index is cached to disk" "ok" \
    "$(run 'export XDG_CACHE_HOME="@TMP@/cache2"; rm -rf "$XDG_CACHE_HOME"; _hop_candidates >/dev/null; [ -s "$XDG_CACHE_HOME/hop/index" ] && printf ok')"

  # With no index at all there is nothing to serve, so this one call pays for
  # the scan -- and must come back with the answer, not with an empty list.
  eq "a missing index is built before answering" "coldish" \
    "$(run 'export XDG_CACHE_HOME="@TMP@/cachecold"; rm -rf "$XDG_CACHE_HOME"; mkdir -p "@TMP@/Code/coldish"; _hop_candidates | grep -x coldish; rmdir "@TMP@/Code/coldish"')"

  # The whole point. A tab press must never wait on a filesystem walk, so an
  # expired index is handed over exactly as it stands and the rescan happens
  # behind the user's back.
  eq "an expired index is served as it stands, then refreshed behind you" \
    "served-stale refreshed" \
    "$(run 'export XDG_CACHE_HOME="@TMP@/cachebg"; rm -rf "$XDG_CACHE_HOME"; _hop_candidates >/dev/null
      mkdir -p "@TMP@/Code/latecomer"; printf "0\n" > "$XDG_CACHE_HOME/hop/stamp"
      case "$(_hop_candidates)" in *latecomer*) printf "blocked " ;; *) printf "served-stale " ;; esac
      n=0; while [ "$n" -lt 100 ]; do
        case "$(cat "$XDG_CACHE_HOME/hop/index")" in *latecomer*) break ;; esac
        sleep 0.05; n=$((n + 1))
      done
      case "$(cat "$XDG_CACHE_HOME/hop/index")" in *latecomer*) printf refreshed ;; *) printf stale-forever ;; esac
      rmdir "@TMP@/Code/latecomer"')"

  # Serving stale would be a false economy if every tab press in the stale
  # window started its own scan, so the first one claims the refresh.
  eq "a burst of tab presses starts one rescan, not one each" "2" \
    "$(run 'export XDG_CACHE_HOME="@TMP@/cachestorm" HOP_FIND_LOG="@TMP@/findlog"; rm -rf "$XDG_CACHE_HOME"
      mkdir -p "@TMP@/stub2"
      printf "#!/bin/sh\nprintf x >> \"\$HOP_FIND_LOG\"\nexec %s \"\$@\"\n" "$(command -v find)" > "@TMP@/stub2/find"
      chmod +x "@TMP@/stub2/find"; : > "$HOP_FIND_LOG"; PATH="@TMP@/stub2:$PATH"
      _hop_candidates >/dev/null
      mkdir -p "@TMP@/Code/stormy"; printf "0\n" > "$XDG_CACHE_HOME/hop/stamp"
      _hop_candidates >/dev/null; _hop_candidates >/dev/null; _hop_candidates >/dev/null
      n=0; while [ "$n" -lt 100 ]; do
        case "$(cat "$XDG_CACHE_HOME/hop/index")" in *stormy*) break ;; esac
        sleep 0.05; n=$((n + 1))
      done
      sleep 0.3; wc -c < "$HOP_FIND_LOG" | tr -d " "
      rmdir "@TMP@/Code/stormy"')"

  # A stamp we cannot read is not a fresh one -- err towards rescanning.
  eq "an unreadable stamp counts as stale" "refreshed" \
    "$(run 'export XDG_CACHE_HOME="@TMP@/cachegarble"; rm -rf "$XDG_CACHE_HOME"; _hop_candidates >/dev/null
      mkdir -p "@TMP@/Code/garbled"; printf "not-a-time\n" > "$XDG_CACHE_HOME/hop/stamp"
      _hop_candidates >/dev/null
      n=0; while [ "$n" -lt 100 ]; do
        case "$(cat "$XDG_CACHE_HOME/hop/index")" in *garbled*) break ;; esac
        sleep 0.05; n=$((n + 1))
      done
      case "$(cat "$XDG_CACHE_HOME/hop/index")" in *garbled*) printf refreshed ;; *) printf stale-forever ;; esac
      rmdir "@TMP@/Code/garbled"')"

  # The rescan is detached rather than backgrounded, so the shell has no job
  # to announce over the prompt the user is typing at.
  eq "the background rescan leaves no job behind" "0" \
    "$(run 'export XDG_CACHE_HOME="@TMP@/cachequiet"; rm -rf "$XDG_CACHE_HOME"; _hop_candidates >/dev/null
      printf "0\n" > "$XDG_CACHE_HOME/hop/stamp"; _hop_candidates >/dev/null
      jobs > "@TMP@/jobs.txt" 2>/dev/null; wc -l < "@TMP@/jobs.txt" | tr -d " "')"

  # HOP_CACHE_TTL=0 is the "do not hand me anything you have not just checked"
  # setting, and has to mean exactly that.
  eq "HOP_CACHE_TTL=0 rescans in the foreground" "nowish" \
    "$(run 'export XDG_CACHE_HOME="@TMP@/cachezero"; rm -rf "$XDG_CACHE_HOME"; _hop_candidates >/dev/null
      mkdir -p "@TMP@/Code/nowish"; export HOP_CACHE_TTL=0
      _hop_candidates | grep -x nowish; rmdir "@TMP@/Code/nowish"')"
done


# -- syntax and packaging -----------------------------------------------------
SH=static
for shell in $SHELLS; do
  if "$shell" -n "$HOP_SH" 2>/dev/null; then ok; else bad "hop.sh parses under $shell" "clean parse" "syntax error"; fi
done
if command -v zsh >/dev/null 2>&1; then
  if zsh -n "$ROOT/completions/_hop" 2>/dev/null; then ok; else bad "completions/_hop parses" "clean parse" "syntax error"; fi
fi
if sh -n "$ROOT/install.sh" 2>/dev/null; then ok; else bad "install.sh parses" "clean parse" "syntax error"; fi

# -- installer ----------------------------------------------------------------
RC="$TMP/rc/.zshrc"
mkdir -p "$TMP/rc"
printf 'export EXISTING=1\n' > "$RC"
HOP_RC="$RC" sh "$ROOT/install.sh" >/dev/null 2>&1
has "installer sources hop.sh" "$ROOT/hop.sh" "$(cat "$RC")"
has "installer keeps existing rc content" "export EXISTING=1" "$(cat "$RC")"
has "installer adds completions to fpath for zsh" "completions" "$(cat "$RC")"
has "installer registers the completion with compdef" "compdef _hop hop" "$(cat "$RC")"
HOP_RC="$RC" sh "$ROOT/install.sh" >/dev/null 2>&1
eq "installer is idempotent" "1" "$(grep -cF '# >>> hop >>>' "$RC")"
eq "installed rc is valid zsh" "0" "$(zsh -n "$RC" >/dev/null 2>&1; printf %s "$?")"

RC2="$TMP/rc/.bashrc"
HOP_RC="$RC2" sh "$ROOT/install.sh" >/dev/null 2>&1
hasnt "bash rc gets no fpath line" "fpath" "$(cat "$RC2")"
eq "installed bash rc is valid bash" "0" "$(bash -n "$RC2" >/dev/null 2>&1; printf %s "$?")"


# -- arrow-key picker (real pty, zsh only) ------------------------------------
# The picker only engages on a terminal, so a pty is the only way to test it.
if command -v zsh >/dev/null 2>&1 && zsh -c 'zmodload zsh/zpty' 2>/dev/null; then
  SH=pty
  PTY="$TMP/pty"
  mkdir -p "$PTY/Code/CTO/ctocompass" "$PTY/Code/ctoapps/ctocompass" "$PTY/Code/vega/ctocompass"
  pick() { zsh "$ROOT/test/pty-pick.zsh" "$HOP_SH" "$PTY/Code" ctocompass "$@" 2>/dev/null | sed 's|^RESULT:||'; }

  eq "arrow: enter takes the highlighted row" "$PTY/Code/CTO/ctocompass" "$(pick enter)"
  eq "arrow: down moves the highlight" "$PTY/Code/ctoapps/ctocompass" "$(pick down enter)"
  eq "arrow: down twice reaches the third row" "$PTY/Code/vega/ctocompass" "$(pick down down enter)"
  eq "arrow: up from the top wraps to the bottom" "$PTY/Code/vega/ctocompass" "$(pick up enter)"
  eq "arrow: down past the bottom wraps to the top" "$PTY/Code/CTO/ctocompass" "$(pick down down down enter)"
  eq "arrow: j and k move too" "$PTY/Code/ctoapps/ctocompass" "$(pick j enter)"
  eq "arrow: typing a number still selects" "$PTY/Code/ctoapps/ctocompass" "$(pick 2 enter)"
  eq "arrow: ctrl-c cancels without moving" "/" "$(pick ctrl-c)"
  eq "arrow: escape cancels without moving" "/" "$(pick esc)"
  eq "arrow: q cancels without moving" "/" "$(pick q)"

  # `hop --browse` browses everything, narrowing as you type.
  browse() { zsh "$ROOT/test/pty-pick.zsh" "$HOP_SH" "$PTY/Code" "" "$@" 2>/dev/null | sed 's|^RESULT:||'; }

  eq "browse: enter takes the first row" "$PTY/Code/CTO" "$(browse enter)"
  eq "browse: down moves the highlight" "$PTY/Code/ctoapps" "$(browse down enter)"
  eq "browse: typing filters the list" "$PTY/Code/vega" "$(browse type:vega enter)"
  eq "browse: an exact name sorts above a path containing it" \
    "$PTY/Code/ctoapps" "$(browse type:ctoapps enter)"
  eq "browse: backspace widens the filter again" \
    "$PTY/Code/vega" "$(browse type:vegaXX bs bs enter)"
  eq "browse: ctrl-u clears the filter" "$PTY/Code/CTO" "$(browse type:vega ctrl-u type:CTO enter)"
  eq "browse: ctrl-c cancels without moving" "/" "$(browse ctrl-c)"
  eq "browse: enter on an empty result does nothing" "/" "$(browse type:zzznope enter esc)"

  # Redraw geometry. Asserting on $PWD alone cannot see a picker that climbs
  # one line up the screen per keystroke, smearing stale prompts behind it and
  # eating whatever was above -- so render the stream onto a virtual screen and
  # look at it. The harness prints ABOVE1-3 first because a picker at row 1
  # hides the bug: cursor-up clamps at the top of the screen.
  screen() { PTY_RAW=1 zsh "$ROOT/test/pty-pick.zsh" "$HOP_SH" "$PTY/Code" "$@" 2>/dev/null \
               | LC_ALL=C awk -f "$ROOT/test/screen.awk"; }

  scr="$(screen '' type:v type:e type:g type:a)"
  eq "browse redraw leaves exactly one prompt line" "1" "$(printf '%s\n' "$scr" | grep -c 'hop>')"
  eq "browse redraw does not climb over earlier output" "3" \
    "$(printf '%s\n' "$scr" | grep -c '^ABOVE')"
  # One match draws one row -- not a fixed slab of blank lines under it.
  eq "browse height follows the result count" "5" "$(printf '%s\n' "$scr" | wc -l | tr -d ' ')"
  eq "browse renders the filtered row" "1" \
    "$(printf '%s\n' "$scr" | grep -c '/vega$')"

  scr="$(screen ctocompass down down)"
  eq "picker redraw leaves exactly one prompt line" "1" "$(printf '%s\n' "$scr" | grep -c 'hop>')"
  eq "picker redraw does not climb over earlier output" "3" \
    "$(printf '%s\n' "$scr" | grep -c '^ABOVE')"
  eq "picker draws one row per match and nothing more" "7" \
    "$(printf '%s\n' "$scr" | wc -l | tr -d ' ')"
  has "picker prompt names the range it wants" "(1-3, arrows)" "$scr"
else
  printf 'skipping arrow-picker tests (no zsh/zpty)\n'
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

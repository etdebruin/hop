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

  eq "no args cds to the first root" \
    "$TMP/Code" "$(run 'hop >/dev/null 2>&1; printf %s "$PWD"')"

  # -- misses ----------------------------------------------------------------
  out="$(run 'hop zzznope; printf "|%s" "$PWD"')"
  has "no match reports on stderr" "no directory matching" "$out"
  has "no match leaves cwd alone" "|$TMP/elsewhere" "$out"
  eq  "no match exits non-zero" "1" "$(run 'hop zzznope >/dev/null 2>&1; printf %s "$?"')"

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
  has "--version prints a version" "hop 0." "$(run 'hop --version')"
  eq  "unknown option exits 2" "2" "$(run 'hop --bogus >/dev/null 2>&1; printf %s "$?"')"
  eq  "-- ends option parsing" \
    "$TMP/Code/aixcto" "$(run 'hop -- aixcto >/dev/null 2>&1; printf %s "$PWD"')"

  # -- completion index ------------------------------------------------------
  out="$(run 'export XDG_CACHE_HOME="@TMP@/cache"; _hop_candidates')"
  has "candidate index lists basenames" "aixcto" "$out"
  hasnt "candidate index excludes pruned dirs" "evil" "$out"
  # GNU and BSD stat disagree on flags and each prints garbage rather than
  # failing on the other's; the index must survive an unreadable timestamp.
  eq "candidate index survives a stat that returns nonsense" "aixcto" \
    "$(run 'export XDG_CACHE_HOME="@TMP@/cache3"; mkdir -p "@TMP@/stub"; printf "#!/bin/sh\nprintf \"nonsense %%s\\n\" \"\$*\"\n" > "@TMP@/stub/stat"; chmod +x "@TMP@/stub/stat"; PATH="@TMP@/stub:$PATH"; _hop_candidates >/dev/null 2>&1; _hop_candidates 2>&1 | grep -c aixcto >/dev/null && _hop_candidates 2>/dev/null | grep -x aixcto')"

  eq "candidate index is cached to disk" "ok" \
    "$(run 'export XDG_CACHE_HOME="@TMP@/cache2"; _hop_candidates >/dev/null; [ -s "$XDG_CACHE_HOME/hop/index" ] && printf ok')"
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

  # Bare `hop` browses everything, narrowing as you type.
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
else
  printf 'skipping arrow-picker tests (no zsh/zpty)\n'
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

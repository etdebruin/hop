# hop — jump to any directory by name, from anywhere.
#
#   hop aixcto        cd to the directory named aixcto, wherever it lives
#   hop CTO/compass   disambiguate with a path fragment
#   hop              browse everything, type to filter
#   hop --list foo    show every match instead of jumping
#
# Source this file from your shell rc. It must be sourced, not executed:
# changing your working directory is something only the current shell can do.
#
# Config (all optional):
#   HOP_ROOTS      colon-separated dirs to search   (default: ~/Code if it
#                  exists, else $HOME; a leading ~/ is expanded)
#   HOP_DEPTH      how deep to descend              (default: 4)
#   HOP_EXCLUDES   colon-separated dir names to never descend into
#   HOP_PICKER     auto | arrow | numbered | fzf    (default: auto)
#   HOP_QUIET      set to 1 to not print the destination
#   HOP_CACHE_TTL  seconds to reuse the completion index (default: 30)
#
# https://github.com/etdebruin/hop — MIT licensed.

HOP_VERSION="0.2.0"

HOP_DEFAULT_EXCLUDES='.git:.hg:.svn:node_modules:.venv:venv:__pycache__:.tox:target:.next:.nuxt:.svelte-kit:dist:build:out:vendor:Pods:.dart_tool:.terraform:.gradle:.cache:DerivedData:.stack-work:.cargo:bower_components'

# ── searching ────────────────────────────────────────────────────────────────

# Print one existing search root per line.
_hop_roots() {
  local raw root
  raw="${HOP_ROOTS:-}"
  if [ -z "$raw" ]; then
    if [ -d "$HOME/Code" ]; then raw="$HOME/Code"; else raw="$HOME"; fi
  fi
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    case "$root" in
      '~') root="$HOME" ;;
      '~/'*) root="$HOME/${root#\~/}" ;;
    esac
    [ -d "$root" ] || continue
    printf '%s\n' "${root%/}"
  done <<EOF
$(printf '%s\n' "$raw" | tr ':' '\n')
EOF
}

# Print every candidate directory under every root.
_hop_all() {
  local root depth excludes ex first
  depth="${HOP_DEPTH:-4}"
  excludes="${HOP_EXCLUDES-$HOP_DEFAULT_EXCLUDES}"
  while IFS= read -r root; do
    local args
    args=(-L "$root" -mindepth 1 -maxdepth "$depth")
    first=1
    while IFS= read -r ex; do
      [ -n "$ex" ] || continue
      if [ "$first" -eq 1 ]; then args+=('('); first=0; else args+=(-o); fi
      args+=(-name "$ex")
    done <<EOF
$(printf '%s\n' "$excludes" | tr ':' '\n')
EOF
    if [ "$first" -eq 0 ]; then args+=(')' -prune -o); fi
    args+=(-type d -print)
    find "${args[@]}" 2>/dev/null
  done <<EOF
$(_hop_roots)
EOF
}

# _hop_rank <query> [keep-all] — read candidates on stdin, print matches best
# first.
#
# Matches are graded into tiers so an exact name never has to compete with a
# coincidental substring. Jumping wants only the best non-empty tier (so `hop
# api` doesn't offer `apiserver` too); the browser wants everything, ranked,
# because it is a list to look through rather than an answer.
#
# A query containing "/" is matched against the tail of the path instead.
_hop_rank() {
  local query="$1" keep="${2-}" pathmode=0 graded best tab
  tab="$(printf '\t')"

  if [ -z "$query" ]; then
    awk '{ n = split($0, p, "/"); printf "%d\t%s\n", n, $0 }' \
      | LC_ALL=C sort -t "$tab" -k1,1n -k2,2 | cut -f2-
    return 0
  fi

  case "$query" in */*) pathmode=1 ;; esac
  graded="$(awk -v q="$query" -v pathmode="$pathmode" '
    BEGIN { lq = tolower(q); ql = length(q) }
    {
      path = $0
      n = split(path, parts, "/")
      base = parts[n]
      lb = tolower(base)
      lp = tolower(path)
      tier = 0
      if (pathmode) {
        if (length(path) > ql && substr(path, length(path) - ql) == "/" q) tier = 1
        else if (length(path) > ql && substr(lp, length(lp) - ql) == "/" lq) tier = 2
        else if (index(lp, lq) > 0) tier = 4
      } else {
        if (base == q) tier = 1
        else if (lb == lq) tier = 2
        else if (substr(lb, 1, ql) == lq) tier = 3
        else if (index(lb, lq) > 0) tier = 4
      }
      if (tier) printf "%d\t%d\t%s\n", tier, n, path
    }
  ' | LC_ALL=C sort -t "$tab" -k1,1n -k2,2n -k3,3)"

  [ -n "$graded" ] || return 1

  if [ -n "$keep" ]; then
    printf '%s\n' "$graded" | cut -f3-
    return 0
  fi
  best="${graded%%$tab*}"
  printf '%s\n' "$graded" | awk -F'\t' -v t="$best" '$1 == t { sub(/^[^\t]*\t[^\t]*\t/, ""); print }'
}

_hop_search() { _hop_all | _hop_rank "$1"; }

# ── display helpers ──────────────────────────────────────────────────────────

# Abbreviate $HOME to ~ for display.
_hop_tilde() {
  case "$1" in
    "$HOME") printf '~\n' ;;
    "$HOME"/*) printf '~/%s\n' "${1#$HOME/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

_hop_count() {
  if [ -n "$1" ]; then printf '%s\n' "$1" | wc -l | tr -d ' '; else printf '0\n'; fi
}

# A pointer glyph is nicer, but only where the locale can render it.
_hop_mark() {
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *[Uu][Tt][Ff]*) printf '❯' ;;
    *) printf '>' ;;
  esac
}

# Is there a terminal we can actually drive?
_hop_is_tty() {
  [ -t 0 ] || return 1
  [ -r /dev/tty ] && [ -w /dev/tty ] || return 1
  case "${TERM:-}" in ''|dumb) return 1 ;; esac
  return 0
}

# Run a picker with the terminal in raw mode, restoring it whatever happens.
# Returns 2 if raw mode was refused, so callers can fall back rather than fail.
_hop_raw() {
  local fn="$1" arg="$2" saved rc
  saved="$(stty -g </dev/tty 2>/dev/null)"
  [ -n "$saved" ] || return 2
  stty raw -echo </dev/tty 2>/dev/null || return 2
  "$fn" "$arg"
  rc=$?
  stty "$saved" </dev/tty 2>/dev/null
  return $rc
}

# Read one keypress into HOP_KEY. $1 is an optional timeout in seconds, used
# to tell a bare Escape from the start of an arrow-key sequence.
_hop_getch() {
  local t="${1-}" c
  if [ -n "${ZSH_VERSION:-}" ]; then
    if [ -n "$t" ]; then read -t "$t" -k 1 -u 0 -r c </dev/tty || return 1
    else read -k 1 -u 0 -r c </dev/tty || return 1; fi
  else
    if [ -n "$t" ]; then IFS= read -r -t "$t" -n 1 c </dev/tty || return 1
    else IFS= read -r -n 1 c </dev/tty || return 1; fi
  fi
  HOP_KEY="$c"
}

_hop_erase() { printf '\033[%dA\r\033[J' "$(($1 + 1))" >/dev/tty; }

# ── the disambiguation picker ────────────────────────────────────────────────

_hop_draw() {
  local matches="$1" count="$2" sel="$3" buf="$4" drawn="$5" i=1 line disp mark
  mark="$(_hop_mark)"
  {
    [ "$drawn" -eq 1 ] && printf '\033[%dA' "$((count + 1))"
    while IFS= read -r line; do
      disp="$(_hop_tilde "$line")"
      printf '\r\033[2K'
      if [ "$i" -eq "$sel" ]; then
        printf '\033[1;36m%s %2d) %s\033[0m\r\n' "$mark" "$i" "$disp"
      else
        printf '  %2d) %s\r\n' "$i" "$disp"
      fi
      i=$((i + 1))
    done <<EOF
$matches
EOF
    printf '\r\033[2Khop> %s' "$buf"
  } >/dev/tty
}

# Up/Down (or k/j, or ^P/^N) move; Enter takes the highlighted row; typing
# digits still selects by number, exactly as the plain numbered picker does.
_hop_pick_arrow() {
  local matches="$1" count sel=1 buf='' drawn=0 c
  count="$(_hop_count "$matches")"

  while :; do
    _hop_draw "$matches" "$count" "$sel" "$buf" "$drawn"
    drawn=1
    _hop_getch || { _hop_erase "$count"; return 1; }
    c="$HOP_KEY"
    case "$c" in
      "$(printf '\033')")
        if _hop_getch 0.1 && [ "$HOP_KEY" = '[' ] && _hop_getch 0.1; then
          case "$HOP_KEY" in
            A) buf=''; sel=$((sel > 1 ? sel - 1 : count)) ;;
            B) buf=''; sel=$((sel < count ? sel + 1 : 1)) ;;
          esac
        else
          _hop_erase "$count"; return 1
        fi
        ;;
      k|"$(printf '\020')") buf=''; sel=$((sel > 1 ? sel - 1 : count)) ;;
      j|"$(printf '\016')") buf=''; sel=$((sel < count ? sel + 1 : 1)) ;;
      [0-9]) buf="$buf$c" ;;
      "$(printf '\177')"|"$(printf '\010')") buf="${buf%?}" ;;
      q|"$(printf '\003')"|"$(printf '\004')") _hop_erase "$count"; return 1 ;;
      ''|"$(printf '\r')"|"$(printf '\n')")
        if [ -n "$buf" ]; then
          if [ "$buf" -ge 1 ] 2>/dev/null && [ "$buf" -le "$count" ]; then
            sel="$buf"
          else
            buf=''
            continue
          fi
        fi
        _hop_erase "$count"
        printf '%s\n' "$matches" | sed -n "${sel}p"
        return 0
        ;;
    esac
  done
}

# _hop_pick <newline-separated-paths> — print the chosen one. The menu goes to
# the terminal, never to stdout, so the caller can capture the choice.
_hop_pick() {
  local matches="$1" picker reply count rc

  picker="$(_hop_resolve_picker)"

  if [ "$picker" = fzf ]; then
    printf '%s\n' "$matches" | fzf --select-1 --exit-0 --prompt='hop> '
    return $?
  fi

  if [ "$picker" = arrow ]; then
    _hop_raw _hop_pick_arrow "$matches"
    rc=$?
    [ "$rc" -ne 2 ] && return $rc
  fi

  printf '%s\n' "$matches" | awk '{ printf "%2d) %s\n", NR, $0 }' >&2
  printf 'hop> ' >&2
  IFS= read -r reply || { printf '\n' >&2; return 1; }
  case "$reply" in
    ''|*[!0-9]*) printf 'hop: cancelled\n' >&2; return 1 ;;
  esac
  count="$(_hop_count "$matches")"
  if [ "$reply" -lt 1 ] || [ "$reply" -gt "$count" ]; then
    printf 'hop: no such choice: %s\n' "$reply" >&2
    return 1
  fi
  printf '%s\n' "$matches" | sed -n "${reply}p"
}

_hop_resolve_picker() {
  local picker="${HOP_PICKER:-auto}"
  if _hop_is_tty; then
    case "$picker" in
      auto)
        if command -v fzf >/dev/null 2>&1; then printf 'fzf\n'; else printf 'arrow\n'; fi
        ;;
      *) printf '%s\n' "$picker" ;;
    esac
  else
    case "$picker" in
      fzf) printf 'fzf\n' ;;
      *) printf 'numbered\n' ;;
    esac
  fi
}

# ── the browser (bare `hop`) ─────────────────────────────────────────────────

_hop_browse_draw() {
  local matches="$1" mcount="$2" sel="$3" top="$4" vis="$5" q="$6" drawn="$7"
  local i n=0 line mark
  mark="$(_hop_mark)"
  {
    [ "$drawn" -eq 1 ] && printf '\033[%dA' "$((vis + 1))"
    if [ "$mcount" -gt 0 ]; then
      i="$top"
      while IFS= read -r line; do
        printf '\r\033[2K'
        if [ "$i" -eq "$sel" ]; then
          printf '\033[1;36m%s %s\033[0m\r\n' "$mark" "$(_hop_tilde "$line")"
        else
          printf '  %s\r\n' "$(_hop_tilde "$line")"
        fi
        i=$((i + 1)); n=$((n + 1))
      done <<EOF
$(printf '%s\n' "$matches" | sed -n "${top},$((top + vis - 1))p")
EOF
    fi
    while [ "$n" -lt "$vis" ]; do printf '\r\033[2K\r\n'; n=$((n + 1)); done
    if [ "$mcount" -gt 0 ]; then
      printf '\r\033[2Khop> %s  \033[2m(%d/%d)\033[0m' "$q" "$sel" "$mcount"
    else
      printf '\r\033[2Khop> %s  \033[2m(no match)\033[0m' "$q"
    fi
  } >/dev/tty
}

# Browse every candidate, narrowing as you type. Anything printable filters —
# there is no number-selection here, because with thousands of rows a number is
# meaningless and the filter is the whole point.
_hop_browse_loop() {
  local all="$1" q='' matches mcount sel=1 top=1 vis rows drawn=0 c

  rows="$(tput lines 2>/dev/null)"
  case "$rows" in ''|*[!0-9]*) rows=24 ;; esac
  vis=$((rows - 4))
  [ "$vis" -gt 12 ] && vis=12
  [ "$vis" -lt 3 ] && vis=3

  matches="$(printf '%s\n' "$all" | _hop_rank '' keep)"
  mcount="$(_hop_count "$matches")"

  while :; do
    if [ "$sel" -lt "$top" ]; then top="$sel"; fi
    if [ "$sel" -ge "$((top + vis))" ]; then top=$((sel - vis + 1)); fi
    _hop_browse_draw "$matches" "$mcount" "$sel" "$top" "$vis" "$q" "$drawn"
    drawn=1

    _hop_getch || { _hop_erase "$vis"; return 1; }
    c="$HOP_KEY"
    case "$c" in
      "$(printf '\033')")
        if _hop_getch 0.1 && [ "$HOP_KEY" = '[' ] && _hop_getch 0.1; then
          case "$HOP_KEY" in
            A) [ "$sel" -gt 1 ] && sel=$((sel - 1)) ;;
            B) [ "$sel" -lt "$mcount" ] && sel=$((sel + 1)) ;;
          esac
        else
          _hop_erase "$vis"; return 1
        fi
        continue
        ;;
      "$(printf '\020')") [ "$sel" -gt 1 ] && sel=$((sel - 1)); continue ;;
      "$(printf '\016')") [ "$sel" -lt "$mcount" ] && sel=$((sel + 1)); continue ;;
      "$(printf '\003')"|"$(printf '\004')") _hop_erase "$vis"; return 1 ;;
      ''|"$(printf '\r')"|"$(printf '\n')")
        [ "$mcount" -gt 0 ] || continue
        _hop_erase "$vis"
        printf '%s\n' "$matches" | sed -n "${sel}p"
        return 0
        ;;
      "$(printf '\177')"|"$(printf '\010')") q="${q%?}" ;;
      "$(printf '\025')") q='' ;;
      [[:print:]]) q="$q$c" ;;
      *) continue ;;
    esac

    matches="$(printf '%s\n' "$all" | _hop_rank "$q" keep)"
    mcount="$(_hop_count "$matches")"
    sel=1
    top=1
  done
}

_hop_browse() {
  local all picker
  all="$(_hop_all)"
  if [ -z "$all" ]; then
    printf 'hop: nothing to browse under %s\n' "$(_hop_roots | tr '\n' ' ')" >&2
    return 1
  fi

  picker="$(_hop_resolve_picker)"
  if [ "$picker" = fzf ]; then
    printf '%s\n' "$all" | fzf --prompt='hop> '
    return $?
  fi

  _hop_raw _hop_browse_loop "$all"
}

# ── entry point ──────────────────────────────────────────────────────────────

_hop_usage() {
  cat <<'USAGE'
Usage: hop [options] [name]

Jump to a directory by name, from anywhere. With no name, browse everything
and type to narrow it down.

Options:
  -l, --list        list matching directories instead of jumping
  -d, --depth N     how deep to descend (default: 4)
      --roots       print the directories hop searches
  -h, --help        show this help
  -V, --version     show the version

In the picker: arrows (or k/j) move, Enter jumps, Esc cancels. Browsing, any
key you type filters; disambiguating a name, digits select by number.

A name containing "/" is matched against the tail of the path, which is the
quickest way to settle an ambiguous name: hop CTO/compass
USAGE
}

hop() {
  local list=0 query="" matches count target
  local HOP_DEPTH="${HOP_DEPTH:-4}"

  while [ $# -gt 0 ]; do
    case "$1" in
      -l|--list) list=1 ;;
      -d|--depth)
        shift
        [ $# -gt 0 ] || { printf 'hop: --depth needs a number\n' >&2; return 2; }
        HOP_DEPTH="$1"
        ;;
      --roots) _hop_roots; return 0 ;;
      -h|--help) _hop_usage; return 0 ;;
      -V|--version) printf 'hop %s\n' "$HOP_VERSION"; return 0 ;;
      --) shift; [ $# -gt 0 ] && query="$1"; break ;;
      -*) printf 'hop: unknown option: %s\n' "$1" >&2; return 2 ;;
      *) query="$1" ;;
    esac
    shift
  done

  # No name: browse everything. With nothing to draw on (a pipe, a script, a
  # dumb terminal) there is no browsing to do, so fall back to the first root.
  if [ -z "$query" ]; then
    if [ "$list" -eq 1 ]; then
      _hop_all | _hop_rank '' keep
      return 0
    fi
    if _hop_is_tty; then
      target="$(_hop_browse)" || return 1
      [ -n "$target" ] || return 1
    else
      target="$(_hop_roots | head -1)"
      [ -n "$target" ] || { printf 'hop: no search roots exist\n' >&2; return 1; }
    fi
    cd -- "$target" || return 1
    [ -n "${HOP_QUIET:-}" ] || _hop_tilde "$PWD" >&2
    return 0
  fi

  matches="$(_hop_search "$query")"
  if [ -z "$matches" ]; then
    printf 'hop: no directory matching %s\n' "$query" >&2
    return 1
  fi

  if [ "$list" -eq 1 ]; then
    printf '%s\n' "$matches"
    return 0
  fi

  count="$(_hop_count "$matches")"
  if [ "$count" -eq 1 ]; then
    target="$matches"
  else
    target="$(_hop_pick "$matches")" || return 1
    [ -n "$target" ] || return 1
  fi

  cd -- "$target" || return 1
  [ -n "${HOP_QUIET:-}" ] || _hop_tilde "$PWD" >&2
}

# ── completion ───────────────────────────────────────────────────────────────

# Basenames of every candidate directory, for tab-completion. Cached, because
# completion runs on every keystroke-ish; the search itself is always live so a
# directory created a second ago is still reachable.
_hop_candidates() {
  local file ttl now mtime
  file="${XDG_CACHE_HOME:-$HOME/.cache}/hop/index"
  ttl="${HOP_CACHE_TTL:-30}"
  if [ -f "$file" ]; then
    # GNU and BSD stat spell mtime differently, and each *succeeds* on the
    # other's flags while printing something that is not a number: GNU reads
    # -f as "filesystem status" and dumps a block of text. So try both and
    # insist on digits rather than trusting an exit status.
    mtime="$(stat -c %Y "$file" 2>/dev/null)"
    case "$mtime" in ''|*[!0-9]*) mtime="$(stat -f %m "$file" 2>/dev/null)" ;; esac
    case "$mtime" in ''|*[!0-9]*) mtime='' ;; esac
    now="$(date +%s)"
    if [ -n "$mtime" ] && [ "$((now - mtime))" -lt "$ttl" ]; then
      cat "$file"
      return 0
    fi
  fi
  mkdir -p "${file%/*}" 2>/dev/null || { _hop_all | awk -F/ '{ print $NF }' | LC_ALL=C sort -u; return 0; }
  _hop_all | awk -F/ '{ print $NF }' | LC_ALL=C sort -u > "$file.tmp$$" && mv "$file.tmp$$" "$file"
  cat "$file"
}

# bash completion; zsh users get completions/_hop instead.
if [ -n "${BASH_VERSION:-}" ]; then
  _hop_complete_bash() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    COMPREPLY=($(compgen -W "$(_hop_candidates)" -- "$cur"))
  }
  complete -F _hop_complete_bash hop
fi

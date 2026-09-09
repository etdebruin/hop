# hop — jump to any directory by name, from anywhere.
#
#   hop aixcto        cd to the directory named aixcto, wherever it lives
#   hop CTO/compass   disambiguate with a path fragment
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
#   HOP_PICKER     auto | numbered | fzf            (default: auto)
#   HOP_QUIET      set to 1 to not print the destination
#   HOP_CACHE_TTL  seconds to reuse the completion index (default: 30)
#
# https://github.com/etdebruin/hop — MIT licensed.

HOP_VERSION="0.1.0"

HOP_DEFAULT_EXCLUDES='.git:.hg:.svn:node_modules:.venv:venv:__pycache__:.tox:target:.next:.nuxt:.svelte-kit:dist:build:out:vendor:Pods:.dart_tool:.terraform:.gradle:.cache:DerivedData:.stack-work:.cargo:bower_components'

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

# _hop_search <query> — print matching directories, best first.
#
# Matches are graded into tiers and only the best non-empty tier is returned,
# so an exact name never has to compete with a coincidental substring. A query
# containing "/" is matched against the tail of the path instead of the name.
_hop_search() {
  local query="$1" pathmode=0 graded best
  case "$query" in */*) pathmode=1 ;; esac

  graded="$(_hop_all | awk -v q="$query" -v pathmode="$pathmode" '
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
  ' | LC_ALL=C sort -t "$(printf '\t')" -k1,1n -k2,2n -k3,3)"

  [ -n "$graded" ] || return 1
  best="${graded%%$(printf '\t')*}"
  printf '%s\n' "$graded" | awk -F'\t' -v t="$best" '$1 == t { sub(/^[^\t]*\t[^\t]*\t/, ""); print }'
}

# Abbreviate $HOME to ~ for display.
_hop_tilde() {
  case "$1" in
    "$HOME") printf '~\n' ;;
    "$HOME"/*) printf '~/%s\n' "${1#$HOME/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# _hop_pick <newline-separated-paths> — print the chosen one. Menu goes to
# stderr so the caller can capture the choice on stdout.
_hop_pick() {
  local matches="$1" picker reply count
  picker="${HOP_PICKER:-auto}"
  if [ "$picker" = auto ]; then
    if [ -t 0 ] && command -v fzf >/dev/null 2>&1; then picker=fzf; else picker=numbered; fi
  fi

  if [ "$picker" = fzf ]; then
    printf '%s\n' "$matches" | fzf --select-1 --exit-0 --prompt='hop> '
    return $?
  fi

  printf '%s\n' "$matches" | awk '{ printf "%2d) %s\n", NR, $0 }' >&2
  printf 'hop> ' >&2
  IFS= read -r reply || { printf '\n' >&2; return 1; }
  case "$reply" in
    ''|*[!0-9]*) printf 'hop: cancelled\n' >&2; return 1 ;;
  esac
  count="$(printf '%s\n' "$matches" | wc -l | tr -d ' ')"
  if [ "$reply" -lt 1 ] || [ "$reply" -gt "$count" ]; then
    printf 'hop: no such choice: %s\n' "$reply" >&2
    return 1
  fi
  printf '%s\n' "$matches" | sed -n "${reply}p"
}

_hop_usage() {
  cat <<'USAGE'
Usage: hop [options] [name]

Jump to a directory by name, from anywhere. With no name, jumps to the
first search root.

Options:
  -l, --list        list matching directories instead of jumping
  -d, --depth N     how deep to descend (default: 4)
      --roots       print the directories hop searches
  -h, --help        show this help
  -V, --version     show the version

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

  if [ -z "$query" ]; then
    target="$(_hop_roots | head -1)"
    [ -n "$target" ] || { printf 'hop: no search roots exist\n' >&2; return 1; }
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

  count="$(printf '%s\n' "$matches" | wc -l | tr -d ' ')"
  if [ "$count" -eq 1 ]; then
    target="$matches"
  else
    target="$(_hop_pick "$matches")" || return 1
    [ -n "$target" ] || return 1
  fi

  cd -- "$target" || return 1
  [ -n "${HOP_QUIET:-}" ] || _hop_tilde "$PWD" >&2
}

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

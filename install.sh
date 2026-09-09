#!/usr/bin/env sh
# Wires hop into your shell rc. Idempotent — re-running rewrites the block in
# place rather than stacking another copy.
#
#   sh install.sh            # pick the rc from $SHELL
#   HOP_RC=~/.bashrc sh install.sh
set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"
BEGIN='# >>> hop >>>'
END='# <<< hop <<<'

RC="${HOP_RC:-}"
if [ -z "$RC" ]; then
  case "${SHELL:-}" in
    *zsh) RC="$HOME/.zshrc" ;;
    *) RC="$HOME/.bashrc" ;;
  esac
fi

block() {
  printf '%s\n' "$BEGIN"
  printf '[ -f "%s/hop.sh" ] && . "%s/hop.sh"\n' "$DIR" "$DIR"
  case "$RC" in
    *zshrc) printf '[ -n "${ZSH_VERSION:-}" ] && fpath=("%s/completions" $fpath)\n' "$DIR" ;;
  esac
  printf '%s\n' "$END"
}

touch "$RC"
if grep -qF "$BEGIN" "$RC" 2>/dev/null; then
  tmp="$RC.hop.$$"
  awk -v b="$BEGIN" -v e="$END" '
    $0 == b { skip = 1 }
    !skip { print }
    $0 == e { skip = 0 }
  ' "$RC" > "$tmp"
  block >> "$tmp"
  mv "$tmp" "$RC"
  printf 'hop: refreshed the block in %s\n' "$RC"
else
  printf '\n' >> "$RC"
  block >> "$RC"
  printf 'hop: added to %s\n' "$RC"
fi

printf 'Open a new shell (or `. %s`) and try: hop --roots\n' "$RC"

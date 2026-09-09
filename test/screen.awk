# A minimal terminal emulator: replay a raw pty byte stream onto a virtual
# screen and print what would actually be visible.
#
# Asserting on the raw stream is nearly useless -- it is full of cursor moves,
# and a redraw that climbs one line per keystroke looks perfectly reasonable in
# the bytes while smearing stale prompts up the real screen. Rendering it is
# the only way a test can see what the user sees.
#
#   LC_ALL=C awk -f screen.awk < raw-output
#
# Handles CR, LF, CUU/CUD/CUF/CUB (A/B/C/D), EL (K) and ED (J). SGR is ignored,
# which is what we want: colour has no bearing on layout.

function emit(t,   i, ch) {
  for (i = 1; i <= length(t); i++) {
    ch = substr(t, i, 1)
    if (ch == "\r") {
      col = 1
    } else if (ch == "\n") {
      row++
      if (row > maxrow) maxrow = row
    } else {
      while (length(screen[row]) < col - 1) screen[row] = screen[row] " "
      screen[row] = substr(screen[row], 1, col - 1) ch substr(screen[row], col + 1)
      col++
      if (row > maxrow) maxrow = row
    }
  }
}

BEGIN { RS = "\033"; row = 1; col = 1; maxrow = 1 }

{
  s = $0
  if (NR > 1 && match(s, /^\[[0-9;]*[A-Za-z]/)) {
    L = RLENGTH
    seq = substr(s, 1, L)
    s = substr(s, L + 1)
    cmd = substr(seq, L, 1)
    params = substr(seq, 2, L - 2)
    n = (params == "" ? 1 : params + 0)
    if (cmd == "A") { row -= n; if (row < 1) row = 1 }
    else if (cmd == "B") { row += n; if (row > maxrow) maxrow = row }
    else if (cmd == "C") { col += n }
    else if (cmd == "D") { col -= n; if (col < 1) col = 1 }
    else if (cmd == "K") {
      if (params == "2") screen[row] = ""
      else screen[row] = substr(screen[row], 1, col - 1)
    }
    else if (cmd == "J") {
      if (params == "" || params == "0") {
        screen[row] = substr(screen[row], 1, col - 1)
        for (r = row + 1; r <= maxrow; r++) screen[r] = ""
      } else {
        for (r = 1; r <= maxrow; r++) screen[r] = ""
      }
    }
  }
  emit(s)
}

END {
  for (r = 1; r <= maxrow; r++) {
    line = screen[r]
    sub(/[ \t]+$/, "", line)
    print line
  }
}

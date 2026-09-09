#!/usr/bin/env zsh
# Drive hop's interactive picker through a real pty and print where it landed.
#
#   pty-pick.zsh <hop.sh> <roots> <query> <key>...
#
# An empty <query> runs bare `hop`, i.e. the browser.
# Keys: up down enter esc ctrl-c ctrl-u bs q j k <digit>, or type:<text>
#
# Two things this has to get right: output is drained continuously (when the
# pty child exits, zsh reaps the session and anything still buffered is lost),
# and the child sleeps after printing so the last write is always drainable.
zmodload zsh/zpty 2>/dev/null || { print "SKIP: no zsh/zpty"; exit 3 }

HOPSH=$1; ROOTS=$2; QUERY=$3
shift 3

OUT=''
drain() { local c; while zpty -r -t p c 2>/dev/null; do OUT+=$c; done }

# zpty joins its arguments and re-parses them through a shell, so the whole -c
# payload must survive as one word -- and the environment has to be set inside
# it, not via a leading `env`, which would otherwise apply to only the first
# fragment of the split.
CMD="cd /; export HOP_ROOTS=${(q)ROOTS} TERM=xterm-256color; "
if [[ -n $QUERY ]]; then
  CMD+="source ${(q)HOPSH}; hop ${(q)QUERY}; "
else
  CMD+="source ${(q)HOPSH}; hop; "
fi
CMD+='printf "RESULT:%s\n" "$PWD"; sleep 3'
zpty -b p zsh -f -c ${(q)CMD} || exit 3

sleep 1.5
drain

for k in "$@"; do
  case $k in
    up)     seq=$'\e[A' ;;
    down)   seq=$'\e[B' ;;
    enter)  seq=$'\r' ;;
    esc)    seq=$'\e' ;;
    ctrl-c) seq=$'\003' ;;
    ctrl-u) seq=$'\025' ;;
    bs)     seq=$'\177' ;;
    type:*) seq=${k#type:} ;;
    *)      seq=$k ;;
  esac
  zpty -w -n p "$seq"
  sleep 0.4
  drain
done

sleep 0.6
drain
zpty -d p 2>/dev/null

print -r -- ${OUT//$'\r'/$'\n'} | grep -o 'RESULT:.*' | tail -1

#!/bin/sh
# Act as a shell that answers SIGWINCH late: an OSC 133 prompt on the bottom
# row, redrawn 150 ms after every resize. The terminal erases the prompt at
# the resize, so the gap is what a loaded device stretches a real shell's to.
prompt() {
    printf '\r\033]133;A\007SLOW PROMPT XXXXXXXX> \033]133;B\007'
}

pending=0
trap 'pending=1' WINCH

printf '\033[2J\033[H'
i=1
while [ "$i" -le 45 ]; do
    printf 'PROMPT STABILITY %02d XXXXXXX\n' "$i"
    i=$((i + 1))
done
prompt

n=0
while [ "$n" -lt 1200 ]; do
    sleep 0.05
    if [ "$pending" -eq 1 ]; then
        pending=0
        sleep 0.15
        prompt
    fi
    n=$((n + 1))
done
printf '\033]133;C\007\n'

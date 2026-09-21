#!/bin/sh
# Hold an empty alternate-screen grid inside DEC 2026, then repaint atomically.
printf '\033[?1049h\033[H'
i=0
while [ "$i" -lt 400 ]; do
    printf '\033[?2026h\033[2J\033[H'
    sleep 0.12
    j=1
    while [ "$j" -le 32 ]; do
        printf 'SYNC FRAME %02d  XXXXXXXXXXXXXXX\n' "$j"
        j=$((j + 1))
    done
    printf '\033[?2026l'
    sleep 0.08
    i=$((i + 1))
done
printf '\033[?1049l'

#!/bin/sh
# Stable primary-screen text: no PTY output during the resize animation.
printf '\033[2J\033[H'
i=1
while [ "$i" -le 32 ]; do
    printf 'LINE %02d  RESIZE STATIC CONTENT\n' "$i"
    i=$((i + 1))
done
sleep 120

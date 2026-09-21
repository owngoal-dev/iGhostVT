#!/bin/sh
# Leave the caller's interactive prompt on the bottom terminal row.
printf '\033[2J\033[H'
i=1
while [ "$i" -le 45 ]; do
    printf 'PROMPT STABILITY %02d XXXXXXX\n' "$i"
    i=$((i + 1))
done

#!/usr/bin/env python3
"""A bad network between a remote-access client and its relay, in userspace.

    netem-proxy.py --listen 127.0.0.1:46499 --target relay.example:46405 \
        [--profile NAME] [--delay MS] [--jitter MS] [--rate KBIT] \
        [--buffer KIB] [--blackout EVERY:FOR] [--stall-once AT:FOR] [--log FILE]

Every accepted connection is spliced to --target, byte for byte, so a TLS
ClientHello's SNI reaches the relay untouched. Each direction is shaped on
its own: a one-way delay with jitter (order kept, as TCP would deliver it),
a rate cap, and a bounded queue — past --buffer the proxy stops reading,
and the sender's own TCP feels it, the way a congested link's buffer does.

A blackout delivers nothing in either direction for its length, with both
TCP legs left up: what a train in a tunnel, a lift, or a Wi-Fi handover does
to a long transfer. Packet loss is not modelled — TCP turns it into exactly
these stalls and rate drops, which is what the layers above ever see.

The profile's numbers can be overridden one by one, and SIGUSR1 starts a
ten-second blackout by hand. Stdlib only; no root, no docker.
"""

import argparse
import asyncio
import random
import signal
import sys
import time

PROFILES = {
    # name: (delay ms, jitter ms, rate kbit/s (0 = none), buffer KiB,
    #        repeating blackout "every:for", one blackout "at:for")
    "clean": (0, 0, 0, 1024, "", ""),
    "wifi": (15, 5, 40_000, 1024, "", ""),
    "cellular": (90, 30, 8_000, 512, "", ""),
    "awful": (350, 120, 600, 256, "", ""),
    # A few seconds of nothing, again and again: a handover, a weak cell.
    "flapping": (60, 20, 4_000, 512, "12:6", ""),
    # Longer than the proxy's congestion grace (10 s) but shorter than the
    # app's relayed reply limit (45 s): the host side has to hold on.
    "tunnel": (120, 40, 4_000, 512, "", "6:25"),
    # Longer than the reply limit: the link is lost, and the next one has
    # to clean up after the transfer.
    "deadzone": (120, 40, 4_000, 512, "", "6:60"),
}

STATE = {"blackout_until": 0.0}


def now():
    return time.monotonic()


def log(message):
    print(time.strftime("%H:%M:%S"), message, file=sys.stderr, flush=True)


def in_blackout():
    return now() < STATE["blackout_until"]


def start_blackout(seconds):
    STATE["blackout_until"] = max(STATE["blackout_until"], now() + seconds)
    log(f"blackout {seconds:g} s")


async def blackout_schedule(spec, once):
    if once:
        at, length = (float(x) for x in once.split(":"))
        await asyncio.sleep(at)
        start_blackout(length)
    if spec:
        every, length = (float(x) for x in spec.split(":"))
        while True:
            await asyncio.sleep(every)
            start_blackout(length)


class Direction:
    def __init__(self, label, reader, writer, args):
        self.label = label
        self.reader = reader
        self.writer = writer
        self.args = args
        self.queue = asyncio.Queue()
        self.queued = 0
        self.room = asyncio.Event()
        self.room.set()
        self.total = 0
        self.last_due = 0.0

    async def pump_in(self):
        try:
            while True:
                await self.room.wait()
                data = await self.reader.read(16 * 1024)
                if not data:
                    break
                jitter = random.gauss(0, self.args.jitter / 1000) if self.args.jitter else 0
                due = max(now() + self.args.delay / 1000 + jitter, self.last_due)
                self.last_due = due
                self.queued += len(data)
                if self.queued >= self.args.buffer * 1024:
                    self.room.clear()
                await self.queue.put((due, data))
        except (ConnectionError, OSError):
            pass
        await self.queue.put(None)

    async def pump_out(self):
        rate = self.args.rate * 1000 / 8  # bytes per second
        try:
            while True:
                item = await self.queue.get()
                if item is None:
                    break
                due, data = item
                wait = due - now()
                if wait > 0:
                    await asyncio.sleep(wait)
                while in_blackout():
                    await asyncio.sleep(0.05)
                self.writer.write(data)
                await self.writer.drain()
                self.total += len(data)
                self.queued -= len(data)
                if self.queued < self.args.buffer * 1024 // 2:
                    self.room.set()
                if rate:
                    await asyncio.sleep(len(data) / rate)
        except (ConnectionError, OSError):
            pass
        try:
            self.writer.close()
        except Exception:
            pass


async def handle(client_reader, client_writer, args, counter):
    counter[0] += 1
    number = counter[0]
    peer = client_writer.get_extra_info("peername")
    host, port = args.target.rsplit(":", 1)
    started = now()
    try:
        upstream_reader, upstream_writer = await asyncio.wait_for(
            asyncio.open_connection(host, int(port)), timeout=10
        )
    except Exception as error:
        log(f"#{number} {peer}: upstream failed: {error}")
        client_writer.close()
        return
    log(f"#{number} {peer} open")
    up = Direction("up", client_reader, upstream_writer, args)
    down = Direction("down", upstream_reader, client_writer, args)
    await asyncio.gather(up.pump_in(), up.pump_out(), down.pump_in(), down.pump_out())
    log(f"#{number} closed after {now() - started:.1f} s: up {up.total} B, down {down.total} B")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--listen", default="127.0.0.1:46499")
    parser.add_argument("--target", required=True)
    parser.add_argument("--profile", choices=sorted(PROFILES), default="clean")
    parser.add_argument("--delay", type=float, help="one-way delay, ms")
    parser.add_argument("--jitter", type=float, help="ms, standard deviation")
    parser.add_argument("--rate", type=float, help="kbit/s per direction, 0 for none")
    parser.add_argument("--buffer", type=int, help="KiB queued per direction before reading stops")
    parser.add_argument("--blackout", help="EVERY:FOR seconds, repeating")
    parser.add_argument("--stall-once", help="AT:FOR seconds after start, once")
    args = parser.parse_args()
    delay, jitter, rate, buffer, blackout, once = PROFILES[args.profile]
    args.delay = delay if args.delay is None else args.delay
    args.jitter = jitter if args.jitter is None else args.jitter
    args.rate = rate if args.rate is None else args.rate
    args.buffer = buffer if args.buffer is None else args.buffer
    args.blackout = blackout if args.blackout is None else args.blackout
    args.stall_once = once if args.stall_once is None else args.stall_once

    async def run():
        host, port = args.listen.rsplit(":", 1)
        counter = [0]
        server = await asyncio.start_server(lambda r, w: handle(r, w, args, counter), host, int(port))
        loop = asyncio.get_running_loop()
        loop.add_signal_handler(signal.SIGUSR1, lambda: start_blackout(10))
        loop.add_signal_handler(signal.SIGTERM, server.close)
        log(
            f"listening on {args.listen} -> {args.target}: profile {args.profile}, delay {args.delay:g}±{args.jitter:g} ms, "
            f"rate {args.rate:g} kbit/s, buffer {args.buffer} KiB, blackout {args.blackout or 'none'}"
            + (f", once {args.stall_once}" if args.stall_once else "")
        )
        asyncio.ensure_future(blackout_schedule(args.blackout, args.stall_once))
        async with server:
            try:
                await server.serve_forever()
            except asyncio.CancelledError:
                pass

    try:
        asyncio.run(run())
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()

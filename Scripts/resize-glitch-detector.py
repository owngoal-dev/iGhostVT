#!/usr/bin/env python3
"""Capture vphone display frames and find transient terminal rendering errors.

The capture uses vphone's host control socket, so its pixels come from the
virtual display after iGhostVT has rendered. It does not inspect the terminal
buffer or take snapshots from the app's view hierarchy.

Requires Pillow and NumPy for analysis. Capture needs only Python's stdlib.
"""

import argparse
import base64
import csv
import json
import socket
import statistics
import time
from pathlib import Path


DEFAULT_SOCKET = Path.home() / ".vphone/VMs/vphone/vphone.sock"


def request(socket_path, command):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(5)
        connection.connect(str(socket_path))
        connection.sendall(json.dumps(command).encode() + b"\n")
        with connection.makefile("rb") as response:
            answer = json.loads(response.readline())
    if not answer.get("ok"):
        raise RuntimeError(answer.get("error", "vphone request failed"))
    return answer


def capture(args):
    directory = args.output.resolve()
    directory.mkdir(parents=True, exist_ok=False)
    schedule = []
    for value in args.tap:
        at, x, y = (float(part) for part in value.split(","))
        schedule.append((at, {"t": "tap", "x": x, "y": y, "screen": False}))
    schedule.sort(key=lambda item: item[0])
    frames = []
    events = []
    start_epoch_ns = time.time_ns()
    start = time.monotonic_ns()
    interval_ns = round(1_000_000_000 / args.fps)
    index = 0
    event_index = 0
    try:
        while True:
            now = time.monotonic_ns()
            elapsed = (now - start) / 1_000_000_000
            if elapsed >= args.duration:
                break
            while event_index < len(schedule) and elapsed >= schedule[event_index][0]:
                at, command = schedule[event_index]
                request(args.socket, command)
                events.append({"scheduled_s": at, "sent_s": elapsed, "command": command})
                event_index += 1
            target = start + index * interval_ns
            if now < target:
                time.sleep((target - now) / 1_000_000_000)
            before = time.monotonic_ns()
            result = request(args.socket, {"t": "screenshot"})
            after = time.monotonic_ns()
            image = result.get("image")
            if not image:
                raise RuntimeError("vphone returned no display image")
            name = f"frame-{index:05}.jpg"
            (directory / name).write_bytes(base64.b64decode(image))
            frames.append({
                "file": name,
                "start_s": (before - start) / 1_000_000_000,
                "end_s": (after - start) / 1_000_000_000,
                "time_s": ((before + after) / 2 - start) / 1_000_000_000,
                "epoch_s": (start_epoch_ns + (before + after) / 2 - start) / 1_000_000_000,
            })
            index += 1
    finally:
        (directory / "capture.json").write_text(
            json.dumps({
                "source": "vphone virtual display screenshot",
                "capture_start_epoch_s": start_epoch_ns / 1_000_000_000,
                "requested_fps": args.fps,
                "duration_s": args.duration,
                "frames": frames,
                "events": events,
            }, indent=2) + "\n"
        )
    print(f"Captured {len(frames)} frames in {directory}")
    if len(frames) > 1:
        gaps = [b["time_s"] - a["time_s"] for a, b in zip(frames, frames[1:])]
        print(f"Frame interval: median {statistics.median(gaps) * 1000:.1f} ms, "
              f"maximum {max(gaps) * 1000:.1f} ms")


def parse_roi(value, width, height):
    bounds = [float(part) for part in value.split(",")]
    if len(bounds) != 4 or not (0 <= bounds[0] < bounds[2] <= 1) or not (0 <= bounds[1] < bounds[3] <= 1):
        raise ValueError("ROI must be x0,y0,x1,y1 fractions within 0..1")
    return (round(bounds[0] * width), round(bounds[1] * height),
            round(bounds[2] * width), round(bounds[3] * height))


def analyze(args):
    import numpy as np
    from PIL import Image, ImageDraw

    directory = args.capture.resolve()
    capture_data = json.loads((directory / "capture.json").read_text())
    records = capture_data["frames"]
    if len(records) < 25:
        raise ValueError("Need at least 25 frames to compare before and after a flash")
    first = Image.open(directory / records[0]["file"]).convert("L")
    roi = parse_roi(args.roi, *first.size)
    x0, y0, x1, y1 = roi
    if x1 - x0 < 20 or y1 - y0 < 20:
        raise ValueError("ROI is too small")

    # Choose a settled span before the resize. Capture may include app launch,
    # which must not establish the baseline or count as a resize glitch.
    initial = []
    baseline_records = [record for record in records
                        if args.baseline_start <= record["time_s"] < args.baseline_start + 0.25]
    if len(baseline_records) < 5:
        raise ValueError("Baseline span has fewer than five frames")
    for record in baseline_records:
        frame = np.asarray(Image.open(directory / record["file"]).convert("L"))
        initial.append(np.median(frame[y0:y1, x0:x1]))
    background = statistics.median(initial)

    rows = []
    small_frames = []
    # Keep each band at least eight pixels tall. Splitting a prompt-height ROI
    # into 16 one-pixel bands makes a blinking cursor look like lost text rows.
    band_count = min(16, max(1, (y1 - y0) // 8))
    for record in records:
        image = np.asarray(Image.open(directory / record["file"]).convert("L"))
        if image.shape != (first.height, first.width):
            raise ValueError(f"Frame size changed: {record['file']}")
        crop = image[y0:y1, x0:x1]
        ink = np.abs(crop.astype(np.int16) - background) >= args.ink_threshold
        bands = [float(part.mean()) for part in np.array_split(ink, band_count, axis=0)]
        rows.append({
            "time_s": record["time_s"],
            "ink": float(ink.mean()),
            "mean": float(crop.mean()),
            "bands": bands,
        })
        small_frames.append(crop[::2, ::2].copy())

    inks = np.array([row["ink"] for row in rows])
    means = np.array([row["mean"] for row in rows])
    bands = np.array([row["bands"] for row in rows])
    times = np.array([row["time_s"] for row in rows])
    stable_ink = float(np.median(inks[
        (times >= args.baseline_start) & (times < args.baseline_start + 0.25)
    ]))
    if args.stable_content and stable_ink <= 0.01:
        raise ValueError("Stable-content baseline has too little text ink")
    events = []
    window = max(8, round(args.fps * 0.2))
    for index in range(window, len(rows) - window):
        if times[index] < args.analyze_from:
            continue
        neighbors = np.r_[index - window:index - 2, index + 3:index + window + 1]
        expected_ink = float(np.median(inks[neighbors]))
        expected_mean = float(np.median(means[neighbors]))
        expected_bands = np.median(bands[neighbors], axis=0)
        ink_ratio = inks[index] / expected_ink if expected_ink > 0.01 else 1
        dim = abs(means[index] - expected_mean)
        lost_bands = np.count_nonzero(
            (expected_bands > 0.025) & (bands[index] < expected_bands * 0.4)
        )

        # A frame that differs from both sides while the two sides agree is
        # the shape of a blink. Compare pixels at low resolution to tolerate
        # JPEG noise and cursor changes, then use ink/brightness for the
        # clear-to-background and full-screen flash cases.
        before = small_frames[index - 3].astype(np.int16)
        current = small_frames[index].astype(np.int16)
        after = small_frames[index + 3].astype(np.int16)
        changed_before = float(np.mean(np.abs(current - before) >= 40))
        changed_after = float(np.mean(np.abs(current - after) >= 40))
        return_difference = float(np.mean(np.abs(before - after) >= 40))
        transient_pixels = (min(changed_before, changed_after) >= 0.06
                            and return_difference < min(changed_before, changed_after) * 0.35)
        blank = expected_ink > 0.025 and ink_ratio < 0.6
        stable_blank = args.stable_content and inks[index] < stable_ink * 0.35
        flash = dim > 25
        line_loss = lost_bands >= 3
        if args.stable_content:
            # The fixed-text experiment has a stronger reference than local
            # neighbors. Suppress cursor and resize noise from generic rules.
            blank = flash = line_loss = transient_pixels = False
        if blank or stable_blank or flash or line_loss or transient_pixels:
            events.append({
                "frame": index,
                "time_s": float(times[index]),
                "epoch_s": records[index].get("epoch_s"),
                "reason": ",".join(name for name, active in (
                    ("ink_loss", blank), ("stable_ink_loss", stable_blank),
                    ("brightness", flash),
                    ("line_loss", line_loss), ("pixel_return", transient_pixels)
                ) if active),
                "ink_ratio": round(float(ink_ratio), 3),
                "brightness_delta": round(float(dim), 1),
                "lost_bands": int(lost_bands),
                "pixel_change": round(min(changed_before, changed_after), 3),
                "pixel_return": round(return_difference, 3),
            })

    # Group adjacent flagged frames; keep the worst frame as the example.
    groups = []
    for event in events:
        if not groups or event["frame"] - groups[-1][-1]["frame"] > 3:
            groups.append([event])
        else:
            groups[-1].append(event)
    findings = []
    for group in groups:
        example = max(group, key=lambda event: (
            1 - event["ink_ratio"] + event["brightness_delta"] / 40
            + event["lost_bands"] / 8 + event["pixel_change"]
        ))
        findings.append({
            "start_s": group[0]["time_s"],
            "end_s": group[-1]["time_s"],
            "frames": [event["frame"] for event in group],
            "example": example,
        })

    gaps = np.diff(times)
    report = {
        "source": capture_data["source"],
        "frames": len(records),
        "size": first.size,
        "roi": roi,
        "background_gray": round(float(background), 1),
        "stable_ink_fraction": round(stable_ink, 4) if args.stable_content else None,
        "baseline_start_s": args.baseline_start,
        "analyze_from_s": args.analyze_from,
        "cadence_ms": {
            "median": round(float(np.median(gaps) * 1000), 1),
            "p95": round(float(np.percentile(gaps, 95) * 1000), 1),
            "max": round(float(max(gaps) * 1000), 1),
        },
        "capture_events": capture_data.get("events", []),
        "findings": findings,
    }
    (directory / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    with (directory / "metrics.csv").open("w", newline="") as output:
        writer = csv.writer(output)
        writer.writerow(["frame", "time_s", "epoch_s", "ink_fraction", "mean_gray", "flagged"])
        flagged = {event["frame"] for event in events}
        for index, row in enumerate(rows):
            epoch_s = records[index].get("epoch_s")
            writer.writerow([index, f"{row['time_s']:.6f}",
                             f"{epoch_s:.6f}" if epoch_s is not None else "",
                             f"{row['ink']:.6f}", f"{row['mean']:.3f}", index in flagged])
    for number, finding in enumerate(findings, 1):
        index = finding["example"]["frame"]
        images = []
        before_index = max(0, finding["frames"][0] - 3)
        after_index = min(len(records) - 1, finding["frames"][-1] + 3)
        for frame_index in (before_index, index, after_index):
            frame = Image.open(directory / records[frame_index]["file"]).convert("RGB")
            images.append(frame.crop(roi))
        contact = Image.new("RGB", (images[0].width * 3, images[0].height + 30), "white")
        for position, image in enumerate(images):
            contact.paste(image, (position * image.width, 30))
        ImageDraw.Draw(contact).text((10, 8),
            f"before / suspect / after   frame {index}   {times[index]:.3f}s   {finding['example']['reason']}",
            fill="black")
        contact.save(directory / f"finding-{number:02}.png")
    print(f"Analyzed {len(records)} frames; ROI {roi}; {len(findings)} possible glitches")
    print(f"Cadence: median {report['cadence_ms']['median']} ms, "
          f"p95 {report['cadence_ms']['p95']} ms, max {report['cadence_ms']['max']} ms")
    for number, finding in enumerate(findings, 1):
        example = finding["example"]
        print(f"  {number}. {finding['start_s']:.3f}-{finding['end_s']:.3f}s: "
              f"{example['reason']} (frame {example['frame']})")
    print(f"Review report.json and finding-*.png in {directory}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    capture_parser = commands.add_parser("capture", help="capture vphone display frames")
    capture_parser.add_argument("--socket", type=Path, default=DEFAULT_SOCKET)
    capture_parser.add_argument("--output", type=Path, required=True)
    capture_parser.add_argument("--duration", type=float, default=8)
    capture_parser.add_argument("--fps", type=int, default=60)
    capture_parser.add_argument("--tap", action="append", default=[], metavar="SECONDS,X,Y",
                                help="tap vphone pixel coordinates during capture")
    capture_parser.set_defaults(run=capture)
    analyze_parser = commands.add_parser("analyze", help="analyze a capture directory")
    analyze_parser.add_argument("capture", type=Path)
    analyze_parser.add_argument("--roi", default="0.02,0.08,0.58,0.75",
                                help="stable terminal crop as x0,y0,x1,y1 fractions of image")
    analyze_parser.add_argument("--ink-threshold", type=int, default=45)
    analyze_parser.add_argument("--fps", type=int, default=60,
                                help="sets the baseline window length in frames")
    analyze_parser.add_argument("--baseline-start", type=float, default=0,
                                help="start of a settled quarter-second baseline")
    analyze_parser.add_argument("--analyze-from", type=float, default=0,
                                help="ignore capture startup before this time")
    analyze_parser.add_argument("--stable-content", action="store_true",
                                help="flag frames losing 65%% of baseline text ink; use only with fixed text")
    analyze_parser.set_defaults(run=analyze)
    args = parser.parse_args()
    args.run(args)


if __name__ == "__main__":
    main()

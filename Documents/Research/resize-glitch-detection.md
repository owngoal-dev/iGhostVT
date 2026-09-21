# Resize flicker investigation

## Pixel capture

`Scripts/resize-glitch-detector.py` samples the vphone virtual display through
its host control socket. The frames are compositor output, not PTY text or
view snapshots. It timestamps every frame and reports transient ink loss,
brightness changes, missing bands, and pixels that change then return. Each
finding has before / suspect / after images, `metrics.csv`, and `report.json`.

Use a fixed crop containing terminal text and excluding app controls and the
right edge that the resize itself moves. For the bottom rows of the tested
430×932 display:

```sh
python3 Scripts/resize-glitch-detector.py capture \
  --output /private/tmp/resize-capture --duration 25 --fps 60
python3 Scripts/resize-glitch-detector.py analyze \
  /private/tmp/resize-capture --roi 0.02,0.64,0.58,0.82 \
  --baseline-start 2 --analyze-from 6
```

For a controlled run, fill the screen with numbered lines shorter than the
smallest test width, clear prior scrollback with `ESC[3J`, and leave a silent
program such as `sleep 120` in the foreground. That makes output and wrapping
unlikely to be mistaken for a renderer defect. The iPhone vphone has no resize
handle. `Scripts/resize-glitch-probe.patch` temporarily animates a 0–90 pt
right inset four times, starting three seconds after the terminal mounts.
Apply it to the app, build and install a `.deb` on vphone, capture the run, and
reverse the patch before making a normal package. The tested grid varied
between 43×37 and 34×37.

The detector found a deliberately inserted 90 ms erase and redraw, and found
zero events in a 181-frame static baseline. A 120 fps request through this
vphone API still delivered about 60 frames per second. A flash shorter than
one sampled interval can escape; an empty report is not proof of no flash.
JPEG grayscale can also miss color-only defects. Inspect the contact sheets
and repeat with both a bottom-row crop and a full stable-text crop.

## Reproduced one-row displacement

All runtime A/B runs used `.deb` packages installed on vphone. They drew the
same static numbered primary screen with `sleep` in the foreground, a 128 ms
resize throttle, and four identical inset animations. The app's temporary
`CADisplayLink` probe recorded the UIKit view, Ghostty sublayer frame,
`contentsScale`, and presented IOSurface dimensions each display tick.

| Library build | Display frames | Bottom-crop findings | Scale excursions | Wrong IOSurface height |
| --- | ---: | ---: | ---: | ---: |
| Released libghostty-spm 1.6.20260909 | 1,500 | 3 | 4 | 4 |
| Same source with stale-frame guard | 1,501 | 0 | 0 | 0 |

The normal layer was 783 pt high at scale 3, so its target height was 2349
pixels. In one resize the released library accepted a stale 1057 px wide
IOSurface for a 342.5 pt layer and changed `contentsScale` to 3.086131. That
made the *next* target approximately 2416 px high despite no height change.
Other wrong heights were 2409–2413 px. The corresponding captured pixels
showed a one-row shift that returned with no PTY output from `sleep`:

![Before, displaced, and recovered terminal frames](resize-glitch-sample.png)

The cause is in libghostty-spm's iOS
`Patches/ghostty/0005-ios-metal-rendering.sh`: its `IOSurfaceLayer` patch
accepts frames with arbitrarily mismatched dimensions and recalculates the
layer's `contentsScale` from the old surface width and height. Ghostty's
`Metal.surfaceSize()` then reads layer bounds multiplied by that scale to
allocate the next render target. The library normally anchors the old frame
at the top-left while waiting for a new frame, but changing its scale defeats
that geometry. A fixed library build rejects frames whose dimensions differ
by more than one pixel, retaining the last presented contents until a matching
frame finishes. The change is in the libghostty-spm working tree; it is not
yet a published dependency or part of a normal iGhostVT build.

Earlier 0 ms runs had no displacement while 128 ms runs did. That correlation
made throttling look like the cause. The library A/B at the *same* 128 ms
setting shows the stale-frame scale change is the immediate cause. The app's
existing resize policy is therefore unchanged; the experimental alternate-
screen mode tracker was removed.

## Last-line blink and whole-screen clear

These remain separate from the reproduced row shift. Ghostty's
`Terminal.resize()` calls `Screen.clearPromptForRedraw()` on the primary
screen when the cursor is on an OSC 133 prompt/input line. It replaces the
prompt cells with spaces before the shell redraws them. `shell_redraws_prompt`
defaults to true, and the bundled zsh/bash integration sends OSC 133;A/B
without overriding that flag. This is a concrete mechanism for a last-line
prompt blink, especially if the shell gets CPU time late. It has not yet been
matched to a captured prompt blink; it does not explain a whole-screen clear
while a TUI owns the active screen.

Ghostty also resets synchronized-output mode on every valid resize, even if
the cell grid stays the same. If a TUI has begun a synchronized clear/repaint
cycle when resize lands, an intermediate cleared grid could become visible
before the replacement output arrives. That is a source-based possibility,
not a reproduced cause. A TUI may also deliberately send `CSI 2J` and repaint
in separate PTY writes. To tell those from a compositor blank, a future
capture must pair display frames with timestamped PTY control-sequence events
and layer `contents` identity/size. A clear with a valid, newly presented
IOSurface and matching PTY erase sequence points to terminal content; a
blank with no PTY erase and missing layer contents points to presentation.

The stress runs so far did **not** reproduce a whole-screen clear: four CPU
workers plus a static primary screen, a foreground zsh repainting on WINCH
with and without synchronized output, and continuous foreground output all
had no blank frames while the app remained visible. The most aggressive run
eventually resprung the vphone, so frames after that event were excluded.
This evidence does not rule out the reported defect on a weak physical
device. An iOS 27 simulator host fed a controlled synchronized clear/repaint
sequence, but `simctl` captured white frames covering the status bar and
keyboard even in its no-resize control. Those captures cannot distinguish a
terminal clear from a simulator capture failure and were excluded. Further
runtime work needs the vphone unlocked after the respring, with display,
terminal-grid, and IOSurface observations recorded together.

`Scripts/resize-glitch-state-probe.patch` is a build-checked, test-only app
patch for that run. It samples the active grid's nonblank row/byte counts and
the presented IOSurface dimensions, identity, and scale at each display tick,
then writes a 30-second CSV in the app's Documents directory. Match its epoch
timestamps to the pixel capture. A screenshot that clears while the grid
stays populated and the IOSurface disappears suggests presentation; a grid
that clears while the IOSurface remains valid directs the investigation to
Ghostty's resize logic or PTY output. The per-frame grid read adds CPU load,
so repeat any finding without the probe before treating its frequency as
representative. Apply this patch and the resize animation only to a test
`.deb`, then reverse both before a normal package.

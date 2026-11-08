# Native vector animations

This fork extends pdfpc 4.7.0 with vector timelines drawn by Cairo inside the
existing slide view. The presenter and audience windows share a monotonic
playback clock. A timeline contains path geometry, colors, opacity and semantic
checkpoints; GTK schedules drawing at the display's frame rate.

## Build and run

Use the normal pdfpc dependencies and build commands in the main README:

```sh
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel 4
build/bin/pdfpc --no-install lecture.pdf
```

Place `lecture.vector.json` beside `lecture.pdf`. Each animated PDF page has a
URI link of the form `pdfpc-vector:scene-id` over a static poster. Its rectangle
determines the animation's position and size. The poster remains usable in
ordinary PDF viewers. One vector region is supported per PDF page.

The implementation draws the paths at the current output size, including when
the window is resized or scaled for a high-DPI display. It uses no video file,
browser surface or additional animation window.

## Presenter controls

An animated slide starts paused. Normal Next plays to the next semantic
checkpoint, then pauses. Pressing Next during motion immediately shows the
next checkpoint. Next at the final checkpoint advances the PDF. Previous
returns to the preceding checkpoint and leaves the PDF page at the initial
checkpoint. Entering an animated page backwards shows its completed state.

| Key or control | Action |
| --- | --- |
| Right, Space, normal Next | Play a segment; during motion, skip to its next checkpoint |
| Left, normal Previous | Previous checkpoint, then previous PDF page |
| Ctrl+Right, forward skip button | Immediately show the next checkpoint, staying on this PDF page |
| Ctrl+Left, backward skip button | Immediately show the previous checkpoint, staying on this PDF page |
| `a`, Play/Pause, figure click | Play or pause; a paused continuous run resumes to its original target |
| `r`, restart button | Return to the initial state |
| `e` | Show the final state |
| `v` | Play the whole timeline continuously |
| `[` and `]` | Halve or double the speed, within 0.1 to 8 times normal |

The presenter row shows the latest reached checkpoint, playback state and
speed. Blanking, hiding, freezing or entering the overview pauses time. Resume
after leaving that state. When the audience is frozen, its displayed binding
and time stay fixed while the presenter can navigate normally.

The actions are configurable through normal pdfpc bindings:
`vectorToggle`, `vectorNextCheckpoint`, `vectorPreviousCheckpoint`,
`vectorRestart`, `vectorFinish`, `vectorPlayAll`, `vectorSlower`, `vectorFaster`.

## Timeline format, version 1

The top-level JSON object has `version: 1` and a `scenes` array. Scene IDs are
unique. Each scene contains:

| Field | Meaning |
| --- | --- |
| `id` | Nonempty scene name used by its PDF link |
| `width`, `height` | Positive dimensions in authoring coordinates |
| `duration` | Positive duration in seconds, at most 86400 |
| `background` | Opaque RGBA color, four values in [0, 1] |
| `checkpoints` | Ordered `{time, label}` entries, starting at 0 and ending at duration |
| `objects` | Vector paths in fixed drawing order |

Each object has a unique `id`, a `commands` string, optional `z` (default 0),
optional `fill_rule` (`nonzero` or `evenodd`) and a `keyframes` array. Commands
use absolute coordinates: `M` and `L` consume two values, `C` six, `Q` four and
`Z` none. The path must begin with `M`. Multiple subpaths support glyph holes.

Each keyframe contains `time`, `fill`, `stroke` and `stroke_width`. The first
frame is at time 0 and supplies the flattened `coords` array. Later frames may
omit `coords` to reuse the preceding geometry. Times strictly increase and
remain within the scene. The commands and coordinate count stay fixed for an
object throughout its timeline. Paths with identical coordinates are cached.

Geometry, RGBA values and stroke width interpolate linearly between adjacent
keyframes. Authoring systems can sample their eased animation curves into those
keyframes. A duplicated state at a later time creates a hold. The last state
holds until the scene ends. Checkpoints are deliberate teaching pauses and are
independent of the geometry sampling rate.

`src/classes/vector_scene.vala` implements validation and drawing. The same
class supplies the live viewer and the standalone renderer probe. Invalid
timelines produce a diagnostic and leave the PDF poster visible.

## Tests and rendering probe

With `BUILD_TESTING` enabled (the default), CMake builds `build/bin/vector-probe`
from the same renderer as pdfpc. Python tests need Pillow, pypdf and ReportLab.
The GUI test additionally needs Xvfb, xdotool, dbus-run-session and ImageMagick's
`import`. It owns a private display and session bus.

```sh
ctest --test-dir build --output-on-failure
build/bin/vector-probe validate lecture.vector.json
build/bin/vector-probe render lecture.vector.json scene-id 1.25 state.pdf 1200 650
build/bin/vector-probe benchmark lecture.vector.json scene-id 1920 1040 1000
```

The probe exports PDF, SVG or PNG according to the output suffix. Tests cover
interpolation, held geometry, alpha, glyph holes, scaling, vector PDF output,
malformed data, both native windows, navigation, pause/resume, checkpoint
skipping, freeze/blank/hide, reload, resizing and real input events.

For diagnostics, `PDFPC_VECTOR_MANIFEST` overrides sidecar discovery and
`PDFPC_VECTOR_SPEED` sets the initial speed. Setting `PDFPC_VECTOR_TRACE` writes
JSONL state changes and per-view drawing timings, including completed GTK
presentation timestamps when available. `vectorStatus` prints the current
playback state through the normal action interface. Tracing is off by default.

The benchmark reports drawing cost. Display pacing must be measured from actual
presentation timestamps with the audience and presenter windows active.

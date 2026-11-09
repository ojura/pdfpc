# Native vector animations

This fork extends pdfpc 4.7.0 with vector timelines drawn by Cairo inside the
existing slide view. Presenter and audience share a monotonic playback anchor;
each window samples it when GTK schedules a draw. A timeline contains path
geometry, colors, opacity and semantic checkpoints.

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

### Relocatable packages

Packages such as AppImages can set `PDFPC_DATA_DIR` to the directory containing
`css/`, `icons/` and the relative REST static resources, and `PDFPC_CONFIG_DIR`
to the directory containing `pdfpcrc`. These overrides also apply with
`--no-install`. Unset or empty variables retain the existing installation or
source-tree resource paths. User CSS and user configuration keep their normal
XDG locations.

Launchers can set `PDFPC_TITLE_SUFFIX` to identify their packaged document or
build. A nonempty value is appended in square brackets to both presenter and
audience window titles, preserving the role and PDF title. Unset or empty values
keep the ordinary titles. The viewer treats the suffix as plain text; the
launcher supplies and formats any revision or timestamp.

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

## Playback timing

A common anchor records the scene time, monotonic clock time, speed and target.
Each window takes one monotonic sample when drawing and evaluates that anchor:

```text
elapsed_s = max(0, sample_clock_us - anchor_clock_us) / 1e6
displayed_time = min(target, anchor_time + elapsed_s * speed)
```

Control state advances from the same monotonic time base. GTK frame clocks
schedule redraws and provide presentation feedback. Their raw timestamps remain
in diagnostics, while scene position follows elapsed real time even when a
backend's frame-time prediction drifts. Starting or resuming playback, and
changing speed, establishes a new anchor. A paused window holds its scene state.

Background PDF caching for slide, preview and notes views waits while vector
playback is active. It retains the next page to cache, checks again after
250 ms, and resumes during a manual pause or a pause at a checkpoint.

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
skipping, freeze/blank/hide, reload, resizing, per-view clock evaluation,
final-frame accounting, buffered shutdown traces and real input events.
On Linux, a second GUI run injects a GDK timestamp eight seconds in the future
and verifies intermediate states and actual checkpoint duration in both views.

## Diagnostics and trace interpretation

`PDFPC_VECTOR_MANIFEST` overrides sidecar discovery; `PDFPC_VECTOR_SPEED` sets
the initial speed. `vectorStatus` prints playback state through the normal
action interface. Enable JSONL tracing with a fresh output filename for each
viewer launch:

```sh
PDFPC_VECTOR_TRACE="$PWD/lecture-trace.jsonl" \
    build/bin/pdfpc --no-install lecture.pdf
```

Tracing is off by default. During motion, draw records are buffered; state
changes, paused draws and normal quit flush them. A short stopped-state
collector retrieves delayed GTK completion feedback without requesting
additional draws.

| Record or field | Interpretation |
| --- | --- |
| `state` | Live control change, including the current anchor, target and checkpoint |
| `frame` | A draw from one view, with `frame_clock_id`, `frame_counter`, `sample_clock_us`, raw `frame_time_us`, `displayed_time` and drawing cost |
| `sample_clock_us` | The monotonic timestamp used to evaluate scene position for this draw |
| `timing` | Delayed `completed_timings` for previously recorded draws on a particular clock |
| `work` | Background PDF caching activity, identified by `pdf-prerender-deferred` or `pdf-prerender` in its `work` field |
| `display_backend` | Runtime GDK display type, such as `GdkX11Display` or `GdkWaylandDisplay`, included in trace records |
| `trace-drained` | Stopped-state collection finished or reached its 500 ms budget; `pending_frames` counts feedback still outstanding across all clocks |
| `trace-closed` | Final record on normal quit, including a quit during motion; the buffered tail has been flushed |
| `last_frame_recorded_us` | Monotonic recording watermark in drain/close records; compare it with draw records' `clock_us` to include the final draws |
| `render_us` / `render_cpu_us` | Wall time / drawing-thread CPU time in microseconds; CPU time is `-1` when the optional platform clock is unavailable |

Work records include `view`, one-based `work_page`, monotonic `started_us`,
`wall_us` and `cpu_us`. A deferred operation records zero wall time and
`cpu_us: -1`; executed work records its measured cost, with CPU time `-1`
when that measurement is unavailable.

`frame_clock_id` is stable within one viewer instance. Match each completed
timing to its originating draw using `(frame_clock_id, counter)`. Select a run
using the draw's `scene`, `view` and `playback_id`; the latter identifies its
monotonic anchor. A timing receipt can arrive after a new run starts, so its
current playback metadata can differ from the originating draw.

A completed timing with `presentation_time_us == 0` has no presentation
timestamp. `expired: true` marks feedback that left GTK's history. Count those
cases and feedback still missing separately from positive presentation
timestamps. Equal positive timestamps can represent coalesced draws at one
display refresh.

The probe benchmark reports drawing cost. Use presentation timestamps for
observed delivery intervals, retaining the coverage count for each view and
run. Intervals spanning draws with unavailable, expired or missing timestamps
are unknown-feedback spans; report them separately from verified delivery
gaps. Report the positive-timestamp sample rate separately when feedback is
partial. Wall time includes waiting and scheduling; thread CPU time measures
CPU work on the drawing thread.

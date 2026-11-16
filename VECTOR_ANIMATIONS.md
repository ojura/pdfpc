# Native vector animations

pdfpc draws vector timelines with Cairo inside the slide view. Presenter and
audience share a monotonic playback clock; each window samples it when GTK
schedules a draw. A timeline contains path geometry, colours, opacity and
checkpoints at which playback can pause.

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

Cairo draws the paths at the output resolution, including after a resize or
a change in display scale.

### Runnable example

The repository contains a PDF, its timeline and their Python source:

```sh
build/bin/pdfpc --no-install demo/vector-animation.pdf
```

The square holds its position for one second, moves right for one second, then
fades to half opacity. Use Right or Space to advance through those checkpoints,
or `v` to play all three seconds continuously. The PDF contains the initial
state as a vector poster, so it can also be read without animation support.

To change or regenerate the example, install Python 3 and ReportLab, then run:

```sh
python3 -B demo/vector_animation.py --output-dir build/vector-example
build/bin/pdfpc --no-install build/vector-example/vector-animation.pdf
```

`timeline()` defines the scene used by both the example and the renderer/GUI
tests. `write_example()` draws its first state into the PDF and adds the URI
link. The example test compares the PDF poster with the native renderer, checks
the link rectangle and verifies that the distributed timeline matches its
source. Installation puts this guide in the configured documentation directory
(normally `share/doc/pdfpc`) and the three example files in its `examples/`
subdirectory. The installed example opens with `pdfpc vector-animation.pdf`.

### Relocatable packages

Packages such as AppImages can set `PDFPC_DATA_DIR` to the directory containing
`css/`, `icons/` and the relative REST static resources, and `PDFPC_CONFIG_DIR`
to the directory containing `pdfpcrc`. A nonempty override is used first,
including with `--no-install`. Without an override, Windows first checks the
files relative to the executable: `../share/pdfpc/` for data and
`../etc/pdfpcrc` for configuration. If those files do not exist, or on other
platforms, `--no-install` selects the source tree; otherwise pdfpc uses its
configured installation directories. User CSS and user configuration keep
their normal XDG locations.

Launchers can set `PDFPC_TITLE_SUFFIX` to identify their packaged document or
build. A nonempty value is appended in square brackets to both presenter and
audience window titles, preserving the role and PDF title. Unset or empty values
keep the ordinary titles. The viewer treats the suffix as plain text; the
launcher supplies and formats any revision or timestamp.

## Presenter controls

An animated slide starts paused. Normal Next plays to the next
checkpoint, then pauses. Pressing Next during motion immediately shows the
next checkpoint. Next at the final checkpoint advances the PDF. Previous
shows the preceding checkpoint. At the initial checkpoint, it returns to the
previous PDF page. Entering an animated page backwards shows its completed
state.

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

Starting or resuming vector playback starts or resumes the talk timer too,
including on the first PDF page. Pausing the animation leaves the talk timer
running; use the normal timer controls when the talk itself is paused. Seeking
to a checkpoint, restarting to the initial state or showing the final state
does not start the talk timer.

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
| `objects` | Paths drawn in ascending `z` order |

Each object has a unique `id`, a `commands` string, optional `z` (default 0),
optional `fill_rule` (`nonzero` by default, or `evenodd`) and a `keyframes` array. Commands
use absolute coordinates: `M` and `L` consume two values, `C` six, `Q` four and
`Z` none. The path must begin with `M`. Multiple subpaths support glyph holes.

Scene coordinates start at the upper-left corner, with x increasing rightward
and y downward. Stroke widths use those same units. pdfpc scales the scene
uniformly to fit the link rectangle and centers it there. Drawing is clipped
to both the scene canvas and that rectangle. Any unused margins retain the
underlying PDF. Strokes have round caps and joins.

When drawing over the cached PDF image, the opaque scene background replaces
every physical pixel covered by the fitted poster, including its antialiased
edge. Page transforms, device scale and surface offsets all enter that coverage
calculation. Paths retain their original geometry and scene-canvas clip; nearby
PDF content and unused fit margins remain unchanged. Standalone PDF/SVG exports
retain geometric background coverage rather than pixel rounding.

The object array is sorted by ascending `z`, so larger values appear in front.
Use distinct values when the overlap order matters. The order stays fixed for
the entire timeline; changing geometry or opacity does not reorder the paths.

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

### Validation limits

Every numeric value must be finite and within -1,000,000,000 to 1,000,000,000.
Additional limits are:

| Quantity | Accepted values |
| --- | --- |
| Scenes per file | 1 to 1,000, with unique nonempty IDs |
| Canvas width and height | Greater than zero |
| Scene duration | Greater than zero and at most 86,400 seconds |
| Checkpoints per scene | 2 to 10,000 |
| Objects per scene | 0 to 20,000, with unique nonempty IDs |
| Keyframes per object | 1 to 200,000 |
| Coordinates in each supplied array | Exactly the number required by the commands, at most 200,000 values |
| Stroke width | Nonnegative |
| Each fill/stroke/background RGBA component | 0 to 1; exactly four components |
| Background alpha | Exactly 1 |

Checkpoint times begin at exactly zero, strictly increase and never exceed the
duration. The last checkpoint must differ from the duration by at most one
microsecond. Keyframe times also begin at exactly zero and strictly increase;
the last may exceed the scene duration by at most one microsecond to allow for
numeric rounding. The first keyframe must supply `coords`. Every keyframe must
supply `fill`, `stroke` and `stroke_width`, even when those values are unchanged.

`version` must be the number 1. IDs, path commands, fill rules and checkpoint
labels are strings; numeric strings are not accepted in numeric fields. A
malformed timeline is rejected as a whole. A PDF link referring to a scene ID
absent from the timeline, or an empty link rectangle, leaves that page's poster
visible and prints a diagnostic. When a PDF page has multiple valid vector regions, pdfpc
uses the first and reports the extra region.

`src/classes/vector_scene.vala` implements validation and drawing. The same
class supplies the live viewer and the standalone renderer probe. Invalid
timelines produce a diagnostic and leave the PDF poster visible.

## Tests and rendering probe

With `BUILD_TESTING` enabled (the default), CMake builds `build/bin/vector-probe`
from the same renderer as pdfpc. Python tests need Pillow, pypdf and ReportLab.
The example test additionally needs `pdftoppm` from Poppler. GUI tests need
Xvfb, xdotool, D-Bus and ImageMagick's `import`. They create private displays and
session buses.

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
final-frame accounting, buffered shutdown traces and real input events. The
region-edge suite checks fractional positions and device offsets, neighbouring
PDF pixels, clipped off-canvas paths, and actual GTK windows against their
composed snapshots before and after resizing at display scales one and two.
On Linux, a second GUI run injects a GDK timestamp eight seconds in the future
and verifies intermediate states and actual checkpoint duration in both views.
The trace-writer fixture checks JSON escaping, numeric precision, locale
independence, buffer reuse and completion-array ordering. Both GUI runs strictly
decode the complete JSONL stream after normal quit.

## Diagnostics and trace interpretation

`PDFPC_VECTOR_MANIFEST` selects the timeline JSON file instead of the adjacent
file. `PDFPC_VECTOR_SPEED` sets an initial speed between 0.1 and 8; values
outside that range are ignored. `vectorStatus` prints playback state through
the normal action interface, even when tracing is disabled. Enable JSONL
tracing with a fresh output filename for each viewer launch; an existing file
is appended to:

```sh
PDFPC_VECTOR_TRACE="$PWD/lecture-trace.jsonl" \
    build/bin/pdfpc --no-install lecture.pdf
```

Tracing is off by default. During motion, draw records are buffered; state
changes, paused draws and normal quit flush them. A short stopped-state
collector retrieves delayed GTK completion feedback without requesting
additional draws.

The optional diagnostic owner holds the file, pending feedback and collector;
it does not retain playback. Closing playback cancels collection. A write or
flush failure reports the destination once and disables further file output,
feedback collection and diagnostic CPU sampling. Animation, lecturer controls
and explicit `vectorStatus` output continue normally.

Each event reuses a text buffer, avoiding a temporary JSON object graph for every
frame. Buffered trace output is flushed at 256 KiB. Events are constructed
synchronously on the GTK thread.

| Record or field | Interpretation |
| --- | --- |
| `state` | Live control change, including the current anchor, target and checkpoint |
| `frame` | A draw from one view, with `frame_clock_id`, `frame_counter`, `sample_clock_us`, raw `frame_time_us`, `displayed_time` and drawing cost |
| `clock_us` | Monotonic time at the start of event construction |
| `sample_clock_us` | The monotonic timestamp used to evaluate scene position for this draw |
| `timing` | Delayed `completed_timings` for previously recorded draws on a particular clock |
| `feedback_collected_us` | Monotonic time immediately after querying completed feedback, present whenever `completed_timings` is written |
| `work` | Background PDF caching activity, identified by `pdf-prerender-deferred` or `pdf-prerender` in its `work` field |
| `display_backend` | Runtime GDK display type, such as `GdkX11Display` or `GdkWaylandDisplay`, included in trace records |
| `trace-drained` | Stopped-state collection finished or reached its 500 ms budget; `pending_frames` counts feedback still outstanding across all clocks |
| `trace-closed` | Final record on normal quit, including a quit during motion; the buffered tail has been flushed |
| `last_frame_recorded_us` | Monotonic time sampled immediately before writing the latest draw event; reported in drain/close records |
| `render_us` / `render_cpu_us` | Wall time / drawing-thread CPU time in microseconds; CPU time is `-1` when the optional platform clock is unavailable |

Work records include `view`, one-based `work_page`, monotonic `started_us`,
`wall_us` and `cpu_us`. A deferred operation records zero wall time and
`cpu_us: -1`; executed work records its measured cost, with CPU time `-1`
when that measurement is unavailable.

`frame_clock_id` is stable within one viewer instance. Match each completed
timing to its originating draw using `(frame_clock_id, counter)`. Select a run
using the draw's `scene`, `view` and `playback_id`; the latter identifies its
monotonic anchor. Completion feedback can arrive after a new run starts, so the
timing event's playback metadata can differ from that of the originating draw.

For a positive, non-expired presentation timestamp, check it against the
originating draw's `sample_clock_us` and the timing record's
`feedback_collected_us`. The latter is the upper observation bound and is
sampled after the GDK queries. `clock_us` is sampled earlier, when event
construction begins. Similarly, a drain/close record's
`last_frame_recorded_us` is sampled after the latest frame's `clock_us`;
compare against that event timestamp when checking that the final draws were
included.

A completed timing with `presentation_time_us == 0` means GTK did not provide a
presentation timestamp. `expired: true` marks feedback that left GTK's history. Count those
cases and feedback still missing separately from positive presentation
timestamps. Equal positive timestamps can represent coalesced draws at one
display refresh.

The probe benchmark reports drawing cost. Differences between draw-event
timestamps measure draw cadence, not when the display presented those frames.
For example, Xvfb may mark every frame complete but supply zero presentation
timestamps. That run can still measure draw cadence and cost, while its
display-delivery interval distribution remains empty.

Use positive presentation timestamps for observed delivery intervals and report
completion coverage for each view and run. Coalesce equal timestamps. Keep
intervals crossing unavailable, expired or missing feedback separate from
intervals whose intervening draws all have known timestamps. Report the
positive-timestamp sample rate separately when feedback is partial. Wall time
includes waiting and scheduling; thread CPU time measures work on the drawing
thread.

The GUI test writes these measurements under `timing.views` in `report.json`.
`draw_event_interval_ms` retains every interval within a playing segment.
`filtered_draw_event_interval_ms` additionally requires an event interval
strictly between 0 and 100 ms and a scene-time increment strictly between
0 and 50 ms. `excluded_draw_pairs` counts the first applicable exclusion reason;
`boundary_pairs` counts pairs separated by a pause or a change of playback
state. Both the unfiltered and filtered distributions remain available.

The `presentation` section counts positive, unavailable, expired and missing
feedback separately. `presentation_interval_ms` contains intervals with known
intervening feedback; `unknown_feedback_span_ms` contains spans crossing
unknown feedback. Each entry in `runs` identifies the originating clock, page,
scene, speed, anchor and target. Its `observed_positive_fps` describes only the
observed positive timestamps; `presented_fps` is provided only when every
selected frame in that run has positive feedback. A later repaint with the
same clock/counter supersedes an earlier draw for that identity.

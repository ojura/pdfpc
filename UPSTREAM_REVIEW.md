# Upstream preparation review

Reviewed on 2026-11-09.

The vector feature needs changes to timer and transition integration, resource
resolution on current upstream, installed documentation and tests before an
upstream proposal. Its existing renderer reuse, sparse geometry storage and
shared monotonic playback clock are useful foundations to retain.

## Scope and evidence

| Item | Reviewed revision |
| --- | --- |
| Fork | [e04127a](https://github.com/ojura/pdfpc/commit/e04127a911689a96805b537524f66fcd59dbe798) |
| Fork base, pdfpc 4.7.0 | [e576c13](https://github.com/pdfpc/pdfpc/commit/e576c139c9f5797ea050e1f2bdcb735c699c58f0) |
| Current upstream examined | [0524719](https://github.com/pdfpc/pdfpc/commit/0524719d74da29fd208d576bc718d2054442d58b) |

The fork has seven commits after the base. Its diff changes 28 files, with
2,709 insertions and 81 deletions. Upstream has 32 commits after that base.
Two independent review passes covered implementation, single-source
definitions, public interfaces, documentation and prose. The findings below
preserve both passes and distinguish executable reproductions from source
analysis.

The headless renderer suite passed all eight tests. Two additional probe
experiments reproduced the PNG error-status and JSON-escaping defects below.
The review also passed `git diff --check`. Timer and PDF-transition findings
come from the identified control and draw paths; they still need dedicated
regression tests. This review did not run a new physical-display performance
measurement.

The registered headless command is:

```sh
python3 tests/vector/test_renderer.py build/bin/vector-probe \
    --output /tmp/pdfpc-renderer-review
```

The retained `build/Testing/Temporary/LastTest.log` describes an earlier,
separate run.

P2 identifies work to complete before submitting the affected feature.
P3 identifies maintenance, diagnostic or wording improvements. Recommendations
for splitting the proposal follow the findings.

## Implementation findings

### P2: Normal Next can start animation without starting the talk timer

[PresentationController.next](src/classes/presentation_controller.vala#L1650)
returns when `vector.next()` handles the action. Ordinary slide navigation
reaches `switch_to_slide_number()`, which calls `timer.run()` at line 112.
[VectorPlayback.run_to](src/classes/vector_playback.vala#L217) establishes
the animation anchor but does not start the presentation timer. The action
dispatch paths at controller lines 1000, 1019 and 1371 also do not supply that
timer call.

As a result, Next on an animated first page can move the animation while the
talk timer remains stopped. The same distinction matters after the talk timer
has been paused. [Timer.run](src/classes/timer.vala#L221) implements its start
and resume behavior.

Keep the timer decision in the presentation controller. Give a handled vector
Next the same intended timer behavior as ordinary Next, and decide explicitly
how direct Play/Pause and Play All actions should affect the talk timer. Add
tests for an animated first page and for Next after pausing the timer. Test
the timer state as well as the animation state.

### P2: PDF transitions omit the visible animation state

[View.Pdf.draw](src/classes/view/pdf.vala#L99) suppresses the vector overlay
during a transition. The outgoing image captured at line 454 and incoming
image captured at line 488 come from the PDF renderer, which contains the
static poster. [TransitionManager](src/classes/view/transition_manager.vala#L57)
then receives those images. The presentation window enables these transitions
at [line 49](src/classes/window/presentation.vala#L49).

Leaving a partly completed animation can therefore show its poster during the
transition. Entering an animated page can transition to its poster and then
replace that image with the initial vector state. In addition,
`View.Pdf.vector_can_tick()` at line 64 and
[VectorPlayback.can_play](src/classes/vector_playback.vala#L350) do not account
for the period when the transition hides the vector drawing. An animation
started during that period can advance before the viewer sees it.

Capture the outgoing composed PDF and vector state for transitions, and
compose the intended entering state too. Coordinate playback with the
existing `entering_slide` event so elapsed animation time matches what is
visible. Add a PDF fixture with actual transitions and check leaving a partial
animation, forward entry, backward entry and input during the transition.
The existing GUI fixture does not exercise transitions.

### P2: Adapt resource and title changes to current upstream

The fork adds [Paths.get_data_dir and get_config_dir](src/classes/resource_paths.vala)
to implement `PDFPC_DATA_DIR` and `PDFPC_CONFIG_DIR`. Current upstream already
has [Resources.resolve and resolve_system_config](https://github.com/pdfpc/pdfpc/blob/0524719d74da29fd208d576bc718d2054442d58b/src/classes/resources.vala).
That implementation also checks resources relative to the executable on
Windows.

Put the environment overrides into the upstream resource resolver with a
defined precedence, retaining Windows executable-relative resolution and
`--no-install` behavior. Maintaining a second resource-path implementation
would duplicate these decisions.

Current upstream also assembles both window titles in
[ControllableWindow](https://github.com/pdfpc/pdfpc/blob/0524719d74da29fd208d576bc718d2054442d58b/src/classes/window/controllable.vala)
and passes `is_presenter` to its constructor. The fork appends
`PDFPC_TITLE_SUFFIX` through a helper at
[controllable.vala:164](src/classes/window/controllable.vala#L164) and separate
presenter/presentation constructor changes. Apply the suffix once where
upstream now assembles the title.

These are concrete integration requirements for the newer upstream base.
They should be resolved when preparing that base, with resource tests for
installed paths, `--no-install`, explicit overrides and Windows-relative
paths.

### P2: PNG export can report success when writing the file fails

[vector_probe.vala:46](tests/vector/vector_probe.vala#L46) ignores the return
status from `Cairo.Surface.write_to_png()`. The following `output.status()`
check describes the image surface; it does not report the failed PNG file
write.

Rendering to a PNG whose parent directory does not exist returned exit status
0, did not write a PNG and produced empty stderr in the review experiment. A script
using this exit status can then accept a missing export.

Check the status returned by `write_to_png()`, print the Cairo error and
return a nonzero status. Add a test with an unavailable destination directory.
Keep the existing finish/status checks for PDF and SVG surfaces.

### P3: The benchmark emits invalid JSON for an accepted scene ID

[vector_probe.vala:72](tests/vector/vector_probe.vala#L72) interpolates
`scene.id` into a quoted JSON string through `%s`.
[VectorDeck](src/classes/vector_scene.vala#L299) accepts a nonempty scene ID,
including quote and backslash characters.

The review passed such an ID through validation and then ran the benchmark.
It returned exit status 0 with stdout that a JSON parser rejected. Use
JSON-GLib or an existing JSON writer that escapes strings; test the complete
stdout with a JSON parser using quoted and backslash-containing IDs.
The production trace writer already has tested escaping behavior.

### P3: PDF-to-view transforms have two implementations

[VectorBinding.draw](src/classes/vector_playback.vala#L21) repeats page fit,
centering, zoom and speaker-note offset calculations from
[Renderer.Pdf](src/classes/renderer/pdf.vala#L106). The calculations currently
agree, but any change to page cropping, zoom or note placement must update
both places.

Extract the PDF-page-to-view transform into the renderer or a shared helper.
VectorBinding should add the PDF link rectangle conversion and the scene's
fit inside that rectangle. Verify the shared transform with ordinary pages,
cropped speaker-note pages and zoomed views.

### P3: Separate optional tracing from playback control

[VectorPlayback](src/classes/vector_playback.vala) currently owns timeline
discovery, PDF bindings, navigation, the animation clock, trace-file I/O,
GTK frame-completion history, stopped-state polling and drawing-thread CPU
measurement. Trace fields begin at line 77; closing/draining starts at
line 111; trace construction and accounting occupy lines 365 onward.
[View.Pdf](src/classes/view/pdf.vala) directly invokes these diagnostic methods.

Move optional tracing and its lifetime into an observer or helper. Keep
timeline and playback state testable without starting the full GTK viewer.
Preserve the current reusable JSON writer, buffering, monotonic timestamps,
late completion collection and behavior when tracing is disabled. The
separation should reduce the responsibilities of playback while retaining
the diagnostics already used to investigate rendering.

### P3: Name the GUI test's draw intervals by what it measures

[tests/vector/test_gui.py:527](tests/vector/test_gui.py#L527) selects playing
audience draw records and subtracts their event-construction `clock_us`
values. It retains pairs only when the scene-time increment is below 0.05
seconds and the interval is below 100 ms. The report calls these values
`median_frame_interval_ms`, `frame_intervals_under_20ms` and
`frame_interval_count`.

Those fields measure filtered intervals between draw events. Rename them to
describe that measurement and expose the selection rule and excluded count.
For delivered-frame intervals, join draws to GTK completion records by
`(frame_clock_id, counter)` and use available positive presentation timestamps.
The current trace accounting already provides those identities.

## Public interfaces and documentation

### P2: Button tooltips duplicate configurable key bindings

The presenter controls at
[presenter.vala:645](src/classes/window/presenter.vala#L645),
647, 649 and 652 hardcode `r`, `Ctrl+Left`, `a` and `Ctrl+Right`.
Their actions are configurable in [rc/pdfpcrc:17](rc/pdfpcrc#L17).
A user who changes a binding therefore sees an inaccurate shortcut hint.

Use [PresentationController.get_action_bindings](src/classes/presentation_controller.vala#L1434)
when composing the tooltip. The presenter help window already uses this
lookup at [line 225](src/classes/window/presenter.vala#L225).
If an action is unbound, show its action description without a shortcut.

### P2: Install navigation and loading instructions with the feature

The installed manual still describes Right and Left as slide-only navigation
at [man/pdfpc.in:148](man/pdfpc.in#L148), 151 and 154.
The controller's ordinary Next description at
[presentation_controller.vala:1240](src/classes/presentation_controller.vala#L1240)
has the same limitation. The new
[VECTOR_ANIMATIONS.md](VECTOR_ANIMATIONS.md) explains the changed behavior,
but [man/CMakeLists.txt](man/CMakeLists.txt) and the root installation rules
do not install that guide.

Document checkpoint-aware Next/Previous, the animation actions and default
bindings, adjacent `.vector.json` loading and `pdfpc-vector:` links in the
installed documentation. Explain the resource environment variables and
their interaction with `--no-install` next to that option in
[man/pdfpc.in:74](man/pdfpc.in#L74). Update the relative REST resource
description at [man/pdfpcrc.in:181](man/pdfpcrc.in#L181) to account for
`PDFPC_DATA_DIR`.

Keep the complete format description in one maintained guide and install or
link it from the manual. Correct the ambiguous Previous description in the
current guide to:

> Previous shows the preceding checkpoint. At the initial checkpoint, it
> returns to the previous PDF page.

### P2: Run the vector tests on the maintained upstream branch

[vector-tests.yml:5](.github/workflows/vector-tests.yml#L5) runs push tests
only for `vector-animations`. Its pull-request path filter covers the feature,
but merging it into upstream master would stop push runs. The existing
[Ubuntu](.github/workflows/cmake-ubuntu.yml#L66) and
[Windows](.github/workflows/cmake-windows.yml#L50) workflows build the project
without running the new CTest suite.

Include the maintained upstream branch or integrate these tests into
upstream's existing CI. Keep renderer and navigation regression tests with
the feature they protect.

### P2: Complete the format specification and add a runnable example

The format guide needs the behavior already defined by
[VectorScene](src/classes/vector_scene.vala#L337) and
[VectorBinding.draw](src/classes/vector_playback.vala#L21):

- Authoring coordinates start at the upper-left corner, with positive y
  directed downward.
- Objects are sorted by ascending `z`; array order alone does not define
  the whole paint order.
- Scene fitting preserves aspect ratio and centers the scene within the PDF
  link rectangle.
- Drawing is clipped to that rectangle.
- Strokes use round caps and joins.
- Numeric values must be finite, coordinate array lengths must match the
  command sequence, and the implementation limits scenes, objects,
  keyframes and checkpoints in addition to limiting duration.

The current guide's `objects` description at
[VECTOR_ANIMATIONS.md:103](VECTOR_ANIMATIONS.md#L103) says “fixed drawing order”
without the `z` rule. Document the exact limits from the parser alongside the
other validation rules so authors can diagnose rejected files.

Add a runnable PDF with its timeline and a source example that creates the
link annotation. Derive the example from a shared fixture used by
[test_renderer.py](tests/vector/test_renderer.py#L16) and
[test_gui.py](tests/vector/test_gui.py#L254), so the published example is
exercised by tests. The generic viewer guide should explain the format;
the course's authoring skill should link that guide.

### P3: Use general animation wording in the viewer

The viewer supports vector timelines produced by any compatible authoring
tool. Keep course-specific derivation language in the course and authoring
skill. The action descriptions at
[presentation_controller.vala:1213](src/classes/presentation_controller.vala#L1213),
1222, 1226, 1229, 1232 and 1235 can use:

| Action | Suggested description |
| --- | --- |
| Toggle | Play or pause the current vector animation |
| Restart | Return the current vector animation to its initial state |
| Finish | Show the final animation state |
| Play All | Play the complete animation continuously |
| Slower | Halve animation playback speed |
| Faster | Double animation playback speed |

Use “Vector animation controls” for the presenter/rc section.
Review the related comments in [view/pdf.vala:276](src/classes/view/pdf.vala#L276),
[vector_scene.vala:2](src/classes/vector_scene.vala#L2) and GUI-test findings at
lines 335, 469 and 471 for the same distinction. Describe caching directly as
“retaining the next page until playback pauses.” In the guide, use “Cairo draws
timeline paths at the output resolution” and “Checkpoints mark positions where
Next pauses playback.”

### P3: Remaining prose corrections

These changes retain the technical content while describing current behavior.

| Location | Correction |
| --- | --- |
| [README.rst:5](README.rst#L5) | Describe the feature and link its guide; remove the fork-branch advertisement when preparing upstream. |
| [Guide:3](VECTOR_ANIMATIONS.md#L3) | Use “pdfpc draws vector timelines with Cairo inside the slide view.” Put review/base history in this report. |
| [Guide:24](VECTOR_ANIMATIONS.md#L24) | Remove the unprompted list of video/browser/window alternatives. |
| [Guide:153](VECTOR_ANIMATIONS.md#L153) | Use “PDFPC_VECTOR_MANIFEST selects the timeline JSON file.” |
| [Guide:169](VECTOR_ANIMATIONS.md#L169) | Use “Buffered trace output is flushed at 256 KiB.” Retain the other flush conditions and GTK-thread ownership. |
| [Guide:184](VECTOR_ANIMATIONS.md#L184) | Define `last_frame_recorded_us` as the monotonic time sampled immediately before the latest draw event is written. Compare it with draw records' `clock_us` to include the final draws. Those timestamps are sampled at different points. |
| [Guide:195](VECTOR_ANIMATIONS.md#L195) | Use “GTK completion feedback can arrive after a new run starts, so its current playback metadata can differ from the originating draw.” |
| [Guide:200](VECTOR_ANIMATIONS.md#L200) | Keep older-trace handling only if supporting that externally used format is required; otherwise document the current format. |
| [Guide:204](VECTOR_ANIMATIONS.md#L204) | Use “A completed timing with presentation_time_us == 0 means GTK did not provide a presentation timestamp.” |
| [Guide:212](VECTOR_ANIMATIONS.md#L212) | Distinguish intervals involving unavailable, expired or missing feedback from intervals whose two endpoints have known presentation timestamps. State coverage with the result. |
| [VectorTests.cmake:4](cmake/VectorTests.cmake#L4) | Use “Compile the renderer used by pdfpc.” |
| [src/CMakeLists.txt:151](src/CMakeLists.txt#L151) | Use “Enable per-thread CPU timing when the platform provides the required clock.” |
| [trace_writer_probe.vala:2](tests/vector/trace_writer_probe.vala#L2) | Use “Exercise the production JSON writer directly.” |

## Preparing the proposal

Prepare changes against current upstream and split them by behavior:

1. Adapt resource environment overrides to upstream's existing `Resources`
   implementation. Keep title metadata separate unless it is useful to review
   together with relocation.
2. Submit a coherent vector feature containing the format/parser, renderer,
   PDF binding, playback, controller integration, presenter controls,
   installed documentation, a generic runnable example and tests. Resolve
   the timer and transition issues in this part.
3. Follow with detailed frame-clock, drawing-thread CPU and JSONL diagnostics
   after separating their implementation from playback. Keep basic renderer
   and navigation regression tests with the core feature.

Retain compilation of the production `vector_scene.vala` into the renderer
probe, sparse coordinate reuse between keyframes, cached fixed paths and one
monotonic animation clock shared by both views. These choices already avoid
separate rendering implementations and keep elapsed scene time consistent.

The immediate validation work is specific: timer start/resume, transitions
with partial and entering animation states, write errors and JSON escaping,
resource resolution on the newer upstream base, remapped shortcut tooltips,
installed documentation and a tested authoring example. The course package
can continue to pin its accepted native revision while this preparation is
implemented.

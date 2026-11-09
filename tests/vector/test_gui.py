#!/usr/bin/env python3
"""Exercise real pdfpc windows on a private X display and private session bus."""

import argparse
import json
import math
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True

from reportlab.pdfgen import canvas

from test_renderer import fixture


def wait_for(check, timeout=10, description="condition"):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(0.025)
    raise AssertionError(f"Timed out waiting for {description}")


def read_complete_trace(filename):
    """Reject malformed, duplicate or non-finite JSON after the writer has closed."""
    def unique_object(pairs):
        result = {}
        for name, value in pairs:
            assert name not in result, {"duplicate_json_member": name}
            result[name] = value
        return result

    def reject_constant(value):
        raise AssertionError({"non_json_numeric_constant": value})

    text = filename.read_text(encoding="utf-8")
    assert text.endswith("\n"), "Closed trace has an incomplete final line"
    return [json.loads(line, object_pairs_hook=unique_object, parse_constant=reject_constant)
            for line in text[:-1].split("\n")]


def check_trace_schema(records):
    common = {"event", "clock_us", "page", "scene", "time", "playing", "playback_id",
              "anchor_clock_us", "anchor_time", "speed", "target", "display_backend"}
    extras = {
        "state": {"reason", "checkpoint"},
        "frame": {"view", "displayed_time", "sample_clock_us", "render_us", "render_cpu_us",
                  "width", "height", "cairo_target_type", "cairo_group_target_type",
                  "frame_counter", "frame_time_us", "refresh_interval_us", "frame_clock_id",
                  "completed_timings", "feedback_collected_us"},
        "timing": {"view", "frame_clock_id", "completed_timings", "feedback_collected_us"},
        "work": {"work", "view", "work_page", "started_us", "wall_us", "cpu_us"},
        "trace-drained": {"pending_frames", "last_frame_recorded_us"},
        "trace-closed": {"pending_frames", "last_frame_recorded_us"},
    }
    integers = {"clock_us", "page", "playback_id", "anchor_clock_us", "checkpoint",
                "sample_clock_us", "render_us", "render_cpu_us", "width", "height",
                "cairo_target_type", "cairo_group_target_type", "frame_counter", "frame_time_us",
                "refresh_interval_us", "frame_clock_id", "feedback_collected_us", "work_page",
                "started_us", "wall_us", "cpu_us", "pending_frames", "last_frame_recorded_us"}
    numbers = {"time", "anchor_time", "speed", "target", "displayed_time"}
    strings = {"event", "display_backend", "reason", "view", "work"}
    counts = {}
    presented = 0
    for record in records:
        kind = record.get("event")
        assert kind in extras, record
        expected = common | extras[kind]
        assert record.keys() == expected, {
            "event": kind, "missing": sorted(expected - record.keys()),
            "unexpected": sorted(record.keys() - expected),
        }
        counts[kind] = counts.get(kind, 0) + 1
        for name, value in record.items():
            if name in integers:
                assert type(value) is int, (name, value)
            elif name in numbers:
                assert type(value) in (int, float) and math.isfinite(value), (name, value)
            elif name in strings:
                assert type(value) is str, (name, value)
        assert type(record["playing"]) is bool, record
        assert record["scene"] is None or type(record["scene"]) is str, record
        assert record["clock_us"] > 0 and record["speed"] > 0, record
        if "completed_timings" in record:
            assert type(record["completed_timings"]) is list, record
            assert record["feedback_collected_us"] >= record["clock_us"], record
            for timing in record["completed_timings"]:
                assert timing.keys() == {"counter", "presentation_time_us", "expired"}, timing
                assert type(timing["counter"]) is int and timing["counter"] >= 0, timing
                assert type(timing["presentation_time_us"]) is int, timing
                assert type(timing["expired"]) is bool, timing
                assert 0 <= timing["presentation_time_us"] <= record["feedback_collected_us"], {
                    "event": record, "completion_after_receipt": timing,
                }
                assert not timing["expired"] or timing["presentation_time_us"] == 0, timing
                presented += timing["presentation_time_us"] > 0
    assert counts.keys() == extras.keys(), counts
    return {"records": len(records), "events": counts,
            "positive_presentations_before_feedback_receipt": presented}


def check_frame_clocks(records):
    frames = [event for event in records if event["event"] == "frame" and event["playing"]]
    assert {frame["view"] for frame in frames} == {"presentation", "presenter"}
    clocks = {}
    runs = {}
    maximum_error = 0
    for frame in frames:
        clock_id = frame["frame_clock_id"]
        assert clock_id > 0 and frame["frame_counter"] >= 0, frame
        assert clocks.setdefault(clock_id, frame["view"]) == frame["view"], frame
        anchor = (frame["anchor_clock_us"], frame["anchor_time"], frame["speed"], frame["target"])
        assert frame["playback_id"] == anchor[0] and anchor[0] > 0, frame
        run = runs.setdefault(frame["playback_id"], {"anchor": anchor, "views": set()})
        assert run["anchor"] == anchor, (run, frame)
        run["views"].add(frame["view"])
        assert anchor[0] <= frame["sample_clock_us"] <= frame["clock_us"], frame
        elapsed = max(0, frame["sample_clock_us"] - anchor[0]) / 1_000_000
        expected = min(anchor[3], max(anchor[1], anchor[1] + elapsed * anchor[2]))
        error = abs(frame["displayed_time"] - expected)
        assert error <= 1e-6, {
            "view": frame["view"], "clock": clock_id, "playback": frame["playback_id"],
            "displayed": frame["displayed_time"], "expected": expected, "error": error,
        }
        assert frame["render_us"] >= 0 and frame["render_cpu_us"] >= -1, frame
        maximum_error = max(maximum_error, error)
    assert len(clocks) >= 2, clocks
    assert any(run["views"] == {"presentation", "presenter"} for run in runs.values()), runs
    assert {0.5, 1}.issubset({frame["speed"] for frame in frames})
    return {"playing_frames": len(frames), "clock_count": len(clocks),
            "shared_runs": sum(len(run["views"]) == 2 for run in runs.values()),
            "maximum_time_error_s": maximum_error}


def check_checkpoint_wall_time(records, playback_id, position, future_clock):
    start = next(event for event in records if event["event"] == "state" and
                 event.get("reason") == "play" and event["playback_id"] == playback_id)
    stop = next(event for event in records if event["event"] == "state" and
                event.get("reason") == "checkpoint" and event["playback_id"] == playback_id)
    duration = (position - start["anchor_time"]) / start["speed"]
    # advance() snaps within 1e-7 scene seconds; trace clocks resolve microseconds.
    tolerance = 1e-7 / start["speed"] + 1e-6
    stopped_after = (stop["clock_us"] - start["anchor_clock_us"]) / 1_000_000
    assert stopped_after + tolerance >= duration, (start, stop)
    views = {}
    for view in ("presentation", "presenter"):
        frames = [event for event in records if event["event"] == "frame" and
                  event["view"] == view and event["playback_id"] == playback_id]
        final = next(frame for frame in frames if abs(frame["displayed_time"] - position) < 1e-6)
        first_final_after = (final["clock_us"] - start["anchor_clock_us"]) / 1_000_000
        assert first_final_after + tolerance >= duration, {
            "view": view, "first_final_after_s": first_final_after, "expected_s": duration,
        }
        moving = [frame for frame in frames if start["anchor_time"] < frame["displayed_time"] < position]
        assert moving, {"view": view, "intermediate_frames": 0}
        if future_clock:
            # The injected GDK timestamp passes the target before actual time does.
            assert any(frame["frame_time_us"] >= start["anchor_clock_us"] + duration*1_000_000
                       for frame in moving), {"view": view, "future_GDK_time_missing": True}
        views[view] = {"first_final_after_s": first_final_after, "intermediate_frames": len(moving)}
    return {"expected_s": duration, "stopped_after_s": stopped_after,
            "injected_future_gdk_time": future_clock, "views": views}


def drained_endpoint(records, playback_id, position):
    frames = [event for event in records if event["event"] == "frame"]
    endpoint = [frame for frame in frames if frame["playback_id"] == playback_id and
                not frame["playing"] and abs(frame["displayed_time"] - position) < 1e-6]
    if {frame["view"] for frame in endpoint} != {"presentation", "presenter"}:
        return None
    latest_draw = max(frame["clock_us"] for frame in frames)
    for index in range(len(records) - 1, -1, -1):
        event = records[index]
        if event["event"] == "trace-drained" and event["playback_id"] == playback_id and \
                not event["playing"] and abs(event["time"] - position) < 1e-6 and \
                event["last_frame_recorded_us"] >= latest_draw:
            return records[:index + 1], endpoint
    return None


def check_timing_accounting(records, endpoint):
    # GTK frame counters are local to their clock. A delayed timing event may
    # carry a newer playback_id, so never use its playback id to join feedback.
    draws = {}
    completed = {}
    for event in records:
        if event["event"] == "frame":
            key = (event["frame_clock_id"], event["frame_counter"])
            draws.setdefault(key, event)
        for timing in event.get("completed_timings", []):
            key = (event["frame_clock_id"], timing["counter"])
            assert key in draws, {"unrecorded_completion": key, "event": event}
            assert key not in completed, {"duplicate_completion": key, "event": event}
            assert draws[key]["view"] == event["view"], (draws[key], event)
            assert timing["presentation_time_us"] >= 0, timing
            assert event["feedback_collected_us"] >= timing["presentation_time_us"], (event, timing)
            assert not timing["expired"] or timing["presentation_time_us"] == 0, timing
            completed[key] = timing
    drain = records[-1]
    assert drain["event"] in {"trace-drained", "trace-closed"}, drain
    pending = set(draws) - set(completed)
    assert drain["pending_frames"] == len(pending), (drain, sorted(pending))
    assert drain["clock_us"] >= drain["last_frame_recorded_us"] >= \
        max(frame["clock_us"] for frame in draws.values()), drain
    if drain["event"] == "trace-drained":
        stop = max(event["clock_us"] for event in records if event["event"] == "state" and
                   event["playback_id"] == drain["playback_id"] and not event["playing"])
        assert any(event["event"] == "timing" and event["clock_us"] >= stop for event in records)

    def disposition(key):
        timing = completed.get(key)
        if timing is None:
            return "pending"
        if timing["expired"]:
            return "expired"
        return "presented" if timing["presentation_time_us"] else "unavailable"

    endpoint_status = {}
    for frame in endpoint:
        key = (frame["frame_clock_id"], frame["frame_counter"])
        assert key in draws, frame
        endpoint_status[frame["view"]] = disposition(key)
    counts = {kind: 0 for kind in ("presented", "unavailable", "expired", "pending")}
    for key in draws:
        counts[disposition(key)] += 1
    return {"recorded_frame_keys": len(draws), "feedback": counts,
            "final_draws": endpoint_status}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("pdfpc", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--future-frame-clock", type=Path,
                        help="Test-only preload library that moves GDK frame time into the future")
    options = parser.parse_args()
    if not os.environ.get("PDFPC_VECTOR_TEST_BUS"):
        command = ["dbus-run-session", "--", "env", "PDFPC_VECTOR_TEST_BUS=1",
                   "python3", str(Path(__file__).resolve()), str(options.pdfpc.resolve()),
                   "--output", str(options.output.resolve())]
        if options.future_frame_clock:
            command += ["--future-frame-clock", str(options.future_frame_clock.resolve())]
        return subprocess.run(command).returncode

    output = options.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    source = output / "fixture.vector.json"
    source.write_text(json.dumps(fixture()), encoding="utf-8")
    pdf = output / "fixture.pdf"
    drawing = canvas.Canvas(str(pdf), pagesize=(1000, 750))
    document_title = "Vector GUI title fixture"
    drawing.setTitle(document_title)
    for index in range(3):
        drawing.setFont("Helvetica", 28)
        drawing.drawString(50, 690, f"Vector GUI test, page {index + 1}")
        if index == 1:
            drawing.linkURL("pdfpc-vector:rotation", (50, 100, 950, 640), relative=0,
                            thickness=0)
        drawing.showPage()
    drawing.save()
    trace = output / "trace.jsonl"
    trace.write_text("")

    read_fd, write_fd = os.pipe()
    xvfb_log = (output / "xvfb.log").open("w")
    xvfb = subprocess.Popen(["Xvfb", "-displayfd", str(write_fd), "-screen", "0",
                             "3200x1800x24", "-nolisten", "tcp", "-noreset"],
                            pass_fds=(write_fd,), stdout=xvfb_log, stderr=xvfb_log)
    os.close(write_fd)
    with os.fdopen(read_fd) as display_reader:
        display_number = display_reader.readline().strip()
    if not display_number:
        raise RuntimeError("Xvfb did not start")
    title_suffix = "test-build 0123abcd | 2026-11-09T01:02:03Z"
    environment = {**os.environ, "DISPLAY": f":{display_number}", "GDK_BACKEND": "x11",
                   "PDFPC_TITLE_SUFFIX": title_suffix,
                   "PDFPC_VECTOR_MANIFEST": str(source), "PDFPC_VECTOR_TRACE": str(trace),
                   "XDG_CONFIG_HOME": str(output / "config"),
                   "XDG_CACHE_HOME": str(output / "cache"), "NO_AT_BRIDGE": "1",
                   "GIO_USE_VFS": "local"}
    if options.future_frame_clock:
        library = options.future_frame_clock.resolve()
        assert library.is_file(), library
        previous_path = environment.get("LD_LIBRARY_PATH", "")
        environment["LD_LIBRARY_PATH"] = str(library.parent) + (":" + previous_path if previous_path else "")
        previous_preload = environment.get("LD_PRELOAD", "")
        environment["LD_PRELOAD"] = library.name + (" " + previous_preload if previous_preload else "")
    app_log = (output / "pdfpc.log").open("w")
    app = subprocess.Popen([str(options.pdfpc.resolve()), "-N", "-w", "both",
                            "-Z", "1000:750", "-P", "2", str(pdf)],
                           env=environment, stdout=app_log, stderr=app_log,
                           start_new_session=True)

    def events():
        result = []
        for line in trace.read_text().splitlines():
            try:
                result.append(json.loads(line))
            except json.JSONDecodeError:
                pass
        return result

    def state():
        return next((event for event in reversed(events()) if event["event"] == "state"), None)

    def action(name, expect_reply=True):
        subprocess.run(["dbus-send", "--session", "--print-reply", "--dest=io.github.pdfpc",
                        "/io/github/pdfpc", "io.github.pdfpc.TriggerAction", f"string:{name}"],
                       env=environment, check=expect_reply, capture_output=True, text=True)

    def check_state(page=None, position=None, playing=None):
        current = state()
        return current and (page is None or current["page"] == page) and \
            (position is None or abs(current["time"] - position) < 1e-6) and \
            (playing is None or current["playing"] == playing)

    def assert_resume_held():
        held = state()["time"]
        action("vectorToggle")
        action("vectorPlayAll")
        time.sleep(0.1)
        action("vectorStatus")
        assert check_state(position=held, playing=False), state()

    findings = []
    try:
        wait_for(lambda: app.poll() is None and check_state(page=2, position=0, playing=False),
                 description="initial paused derivation")
        wait_for(lambda: {e.get("view") for e in events() if e["event"] == "frame"} ==
                 {"presentation", "presenter"}, description="both native vector views")
        presenter_id = subprocess.check_output(["xdotool", "search", "--name", "pdfpc - presenter"],
                                               env=environment, text=True).split()[-1]
        audience_id = subprocess.check_output(["xdotool", "search", "--name", "pdfpc - presentation"],
                                              env=environment, text=True).split()[-1]

        def assert_window_titles():
            for role, identifier in (("presenter", presenter_id), ("presentation", audience_id)):
                title = subprocess.check_output(["xdotool", "getwindowname", identifier],
                                                env=environment, text=True).strip()
                assert title == f"pdfpc - {role} ({document_title}) [{title_suffix}]", title

        assert_window_titles()
        findings.append("Both window titles retain the role, PDF title and optional launcher suffix")
        subprocess.run(["xdotool", "windowmove", presenter_id, "0", "0", "windowsize", presenter_id,
                        "1280", "900", "windowmove", audience_id, "1500", "0"],
                       env=environment, check=True)
        findings.append("Both presenter and audience draw the paused initial state")

        action("next")
        first_checkpoint_playback_id = state()["playback_id"]
        wait_for(lambda: check_state(position=1, playing=False), description="first checkpoint")
        assert state()["page"] == 2
        first_records, _ = wait_for(
            lambda: drained_endpoint(events(), first_checkpoint_playback_id, 1), timeout=2,
            description="first checkpoint draws and timing drain")
        first_checkpoint_report = check_checkpoint_wall_time(
            first_records, first_checkpoint_playback_id, 1, bool(options.future_frame_clock))
        findings.append("Next stops at the first semantic checkpoint without changing PDF pages")
        findings.append("Both views and the control stop reach the checkpoint after its actual elapsed duration")

        action("next")
        wait_for(lambda: check_state(playing=True), description="second segment playing")
        time.sleep(0.25)
        action("vectorToggle")
        wait_for(lambda: check_state(playing=False), description="pause inside segment")
        paused = state()["time"]
        assert 1 < paused < 2, state()
        before = len([e for e in events() if e["event"] == "frame"])
        time.sleep(0.25)
        action("vectorStatus")
        assert abs(state()["time"] - paused) < 1e-6
        after = len([e for e in events() if e["event"] == "frame"])
        assert after - before <= 4, (before, after)
        findings.append("Pause freezes the shared clock and removes continuous redraw callbacks")

        action("prev")
        wait_for(lambda: check_state(position=1, playing=False), description="previous checkpoint")
        action("vectorRestart")
        wait_for(lambda: check_state(position=0, playing=False), description="restart")
        findings.append("Previous and restart seek deterministic semantic states")

        action("vectorNextCheckpoint")
        assert check_state(position=1, playing=False), state()
        action("vectorNextCheckpoint")
        assert check_state(position=2, playing=False), state()
        action("vectorNextCheckpoint")
        action("vectorNextCheckpoint")
        assert check_state(page=2, position=3, playing=False), state()
        action("vectorPreviousCheckpoint")
        assert check_state(position=2, playing=False), state()
        action("vectorRestart")
        action("vectorPreviousCheckpoint")
        assert check_state(page=2, position=0, playing=False), state()
        findings.append("Dedicated checkpoint controls seek immediately and stay on the current slide")

        action("vectorPlayAll")
        time.sleep(0.2)
        action("vectorToggle")
        assert state()["target"] == 3 and not state()["playing"], state()
        action("vectorToggle")
        assert state()["target"] == 3 and state()["playing"], state()
        continuous_playback_id = state()["playback_id"]
        wait_for(lambda: any(e.get("reason") == "checkpoint-passed" and
                            e.get("checkpoint") == 1 and e.get("playing")
                            for e in events()), description="continuous checkpoint status")
        wait_for(lambda: check_state(position=3, playing=False), description="resumed continuous playback")
        findings.append("Play/pause preserves continuous playback and updates crossed-checkpoint status")
        drained, endpoint = wait_for(
            lambda: drained_endpoint(events(), continuous_playback_id, 3), timeout=2,
            description="both final draws and post-stop timing drain")
        endpoint_report = check_timing_accounting(drained, endpoint)
        findings.append("Final draws and delayed timing feedback are accounted for by clock and frame counter")
        action("vectorRestart")

        action("vectorPlayAll")
        time.sleep(0.2)
        action("freeze")
        wait_for(lambda: check_state(playing=False), description="freeze pauses playback")
        assert_resume_held()
        frozen = state()["time"]
        action("nextForced")
        wait_for(lambda: check_state(page=3), description="navigate while audience frozen")
        audience = [e for e in events() if e["event"] == "frame" and e["view"] == "presentation"]
        assert audience and abs(audience[-1]["displayed_time"] - frozen) < 0.04
        action("freeze")
        action("prevForced")
        wait_for(lambda: check_state(page=2, position=3), description="backward page entry at final state")
        findings.append("Freeze keeps the audience state while presenter navigation continues")

        action("vectorRestart")
        action("vectorPlayAll")
        time.sleep(0.15)
        action("blank")
        wait_for(lambda: check_state(playing=False), description="blank pauses playback")
        assert_resume_held()
        action("blank")
        action("vectorPlayAll")
        time.sleep(0.15)
        action("hide")
        wait_for(lambda: check_state(playing=False), description="hide pauses playback")
        assert_resume_held()
        action("hide")
        findings.append("Blank, hide and freeze hold time and reject resume attempts")

        action("vectorRestart")
        action("vectorSlower")
        action("vectorPlayAll")
        prerender_playback_id = state()["playback_id"]
        wait_for(lambda: check_state(position=3, playing=False), timeout=8, description="half-speed continuous playback")
        findings.append("Continuous playback reaches its exact final state at half speed")
        work = [event for event in events() if event["event"] == "work"]
        assert any(event["work"] == "pdf-prerender-deferred" and event["playing"] and
                   event["playback_id"] == prerender_playback_id for event in work), work
        assert not any(event["work"] == "pdf-prerender" and event["playing"] for event in work), work
        wait_for(lambda: any(event["event"] == "work" and event["work"] == "pdf-prerender" and
                             not event["playing"] and event["playback_id"] == prerender_playback_id
                             for event in events()), timeout=1.5,
                 description="deferred PDF prerender resumes after the checkpoint")
        findings.append("PDF prerendering defers during motion and resumes after the paused checkpoint")

        action("next")
        wait_for(lambda: check_state(page=3), description="next leaves completed derivation")
        action("prevForced")
        wait_for(lambda: check_state(page=2), description="return to derivation")
        action("reload")
        wait_for(lambda: check_state(page=2, position=0, playing=False), description="reload resets timeline")
        assert_window_titles()
        findings.append("Completed next, backward entry and document reload preserve navigation")

        subprocess.run(["xdotool", "windowsize", audience_id, "1200", "900"],
                       env=environment, check=True)
        wait_for(lambda: any(e.get("view") == "presentation" and e.get("width") == 1200
                            for e in events() if e["event"] == "frame"), description="resized vector view")
        subprocess.run(["xdotool", "mousemove", "--window", audience_id, "500", "350", "click", "1"],
                       env=environment, check=True)
        wait_for(lambda: check_state(playing=True), description="native PDF animation link click")
        action("vectorToggle")
        subprocess.run(["xdotool", "key", "--window", presenter_id, "r"],
                       env=environment, check=True)
        wait_for(lambda: check_state(position=0, playing=False), description="restart keyboard binding")
        subprocess.run(["xdotool", "key", "--window", presenter_id, "Right"],
                       env=environment, check=True)
        wait_for(lambda: check_state(position=1, playing=False), description="next keyboard binding")
        action("vectorRestart")
        findings.append("Resize, native PDF link click and real keyboard bindings work")

        time.sleep(0.1)
        subprocess.run(["import", "-window", presenter_id, str(output / "presenter.png")],
                       env=environment, check=True)
        subprocess.run(["import", "-window", audience_id, str(output / "presentation.png")],
                       env=environment, check=True)

        action("vectorPlayAll")
        shutdown_playback_id = state()["playback_id"]
        time.sleep(0.1)
        visible_before_quit = sum(event["event"] == "frame" and
                                  event["playback_id"] == shutdown_playback_id for event in events())
        # GTK may exit before D-Bus delivers the quit reply; verify the actual
        # clean exit and terminal trace record instead of requiring that reply.
        action("quit", expect_reply=False)
        assert app.wait(timeout=5) == 0, app.returncode
        records = read_complete_trace(trace)
        schema_report = check_trace_schema(records)
        findings.append("Every final trace line preserves the JSON schema and records completed feedback receipt")
        closed = records[-1]
        assert closed["event"] == "trace-closed" and closed["playing"], closed
        assert closed["playback_id"] == shutdown_playback_id, closed
        assert sum(event["event"] == "trace-closed" for event in records) == 1
        shutdown_frames = [event for event in records if event["event"] == "frame" and
                           event["playback_id"] == shutdown_playback_id]
        assert {frame["view"] for frame in shutdown_frames} == {"presentation", "presenter"}
        assert len(shutdown_frames) > visible_before_quit, (len(shutdown_frames), visible_before_quit)
        shutdown_report = check_timing_accounting(records, shutdown_frames)
        shutdown_report["new_run_frames"] = len(shutdown_frames)
        shutdown_report["buffered_frames_preserved"] = len(shutdown_frames) - visible_before_quit
        findings.append("Quit during motion preserves buffered draws and closes the trace with complete accounting")

        clock_report = check_frame_clocks(records)
        findings.append("Both views evaluate monotonic draw samples from the shared playback anchor")
        frames = [e for e in records if e["event"] == "frame" and e["view"] == "presentation" and e["playing"]]
        clock_intervals = [(b["clock_us"] - a["clock_us"])/1000 for a, b in zip(frames, frames[1:])
                           if 0 < b["displayed_time"] - a["displayed_time"] < 0.05 and
                           b["clock_us"] - a["clock_us"] < 100000]
        render_us = sorted(e["render_us"] for e in frames)
        report = {"checks": findings, "animated_audience_frames": len(frames),
                  "trace_schema": schema_report,
                  "per_view_clocks": clock_report, "endpoint_timing": endpoint_report,
                  "first_checkpoint_timing": first_checkpoint_report,
                  "shutdown_timing": shutdown_report,
                  "audience_render_p95_ms": render_us[int(len(render_us)*0.95)]/1000,
                  "median_frame_interval_ms": sorted(clock_intervals)[len(clock_intervals)//2],
                  "frame_intervals_under_20ms": sum(x < 20 for x in clock_intervals),
                  "frame_interval_count": len(clock_intervals)}
        (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2))
    finally:
        if app.poll() is None:
            os.killpg(app.pid, signal.SIGTERM)
            try:
                app.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(app.pid, signal.SIGKILL)
                app.wait()
        xvfb.terminate()
        xvfb.wait(timeout=5)
        app_log.close()
        xvfb_log.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

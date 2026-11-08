#!/usr/bin/env python3
"""Exercise real pdfpc windows on a private X display and private session bus."""

import argparse
import json
import os
import signal
import subprocess
import time
from pathlib import Path

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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("pdfpc", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    options = parser.parse_args()
    if not os.environ.get("PDFPC_VECTOR_TEST_BUS"):
        command = ["dbus-run-session", "--", "env", "PDFPC_VECTOR_TEST_BUS=1",
                   "python3", str(Path(__file__).resolve()), str(options.pdfpc.resolve()),
                   "--output", str(options.output.resolve())]
        return subprocess.run(command).returncode

    output = options.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    source = output / "fixture.vector.json"
    source.write_text(json.dumps(fixture()), encoding="utf-8")
    pdf = output / "fixture.pdf"
    drawing = canvas.Canvas(str(pdf), pagesize=(1000, 750))
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
    environment = {**os.environ, "DISPLAY": f":{display_number}", "GDK_BACKEND": "x11",
                   "PDFPC_VECTOR_MANIFEST": str(source), "PDFPC_VECTOR_TRACE": str(trace),
                   "XDG_CONFIG_HOME": str(output / "config"),
                   "XDG_CACHE_HOME": str(output / "cache"), "NO_AT_BRIDGE": "1",
                   "GIO_USE_VFS": "local"}
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

    def action(name):
        subprocess.run(["dbus-send", "--session", "--print-reply", "--dest=io.github.pdfpc",
                        "/io/github/pdfpc", "io.github.pdfpc.TriggerAction", f"string:{name}"],
                       env=environment, check=True, capture_output=True, text=True)

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
        subprocess.run(["xdotool", "windowmove", presenter_id, "0", "0", "windowsize", presenter_id,
                        "1280", "900", "windowmove", audience_id, "1500", "0"],
                       env=environment, check=True)
        findings.append("Both presenter and audience draw the paused initial state")

        action("next")
        wait_for(lambda: check_state(position=1, playing=False), description="first checkpoint")
        assert state()["page"] == 2
        findings.append("Next stops at the first semantic checkpoint without changing PDF pages")

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
        wait_for(lambda: any(e.get("reason") == "checkpoint-passed" and
                            e.get("checkpoint") == 1 and e.get("playing")
                            for e in events()), description="continuous checkpoint status")
        wait_for(lambda: check_state(position=3, playing=False), description="resumed continuous playback")
        findings.append("Play/pause preserves continuous playback and updates crossed-checkpoint status")
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
        wait_for(lambda: check_state(position=3, playing=False), timeout=8, description="half-speed continuous playback")
        findings.append("Continuous playback reaches its exact final state at half speed")

        action("next")
        wait_for(lambda: check_state(page=3), description="next leaves completed derivation")
        action("prevForced")
        wait_for(lambda: check_state(page=2), description="return to derivation")
        action("reload")
        wait_for(lambda: check_state(page=2, position=0, playing=False), description="reload resets timeline")
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

        frames = [e for e in events() if e["event"] == "frame" and e["view"] == "presentation" and e["playing"]]
        clock_intervals = [(b["clock_us"] - a["clock_us"])/1000 for a, b in zip(frames, frames[1:])
                           if 0 < b["displayed_time"] - a["displayed_time"] < 0.05 and
                           b["clock_us"] - a["clock_us"] < 100000]
        render_us = sorted(e["render_us"] for e in frames)
        report = {"checks": findings, "animated_audience_frames": len(frames),
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

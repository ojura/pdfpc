"""Separate vector draw-event timing from GTK presentation feedback."""
from __future__ import annotations

import math
import statistics


def distribution(values):
    """Use a median and the same indexed percentiles as the GUI profiler."""
    if not values:
        return None
    ordered = sorted(values)
    return {"count": len(ordered), "mean": statistics.mean(ordered),
            "p50": statistics.median(ordered),
            "p95": ordered[min(len(ordered) - 1, int(len(ordered) * .95))],
            "p99": ordered[min(len(ordered) - 1, int(len(ordered) * .99))],
            "max": ordered[-1]}


def frame_key(event):
    return event["frame_clock_id"], event["frame_counter"]


def run_key(event):
    return (event["frame_clock_id"], event["playback_id"], event["page"],
            event["scene"], event["speed"], event["anchor_time"], event["target"])


def _feedback(records, origins):
    completed = {}
    for event in records:
        if "completed_timings" not in event:
            continue
        collected = event.get("feedback_collected_us")
        if type(collected) is not int or collected <= 0 or collected < event["clock_us"]:
            raise ValueError("Invalid feedback collection timestamp")
        for timing in event["completed_timings"]:
            key = event["frame_clock_id"], timing["counter"]
            if key not in origins:
                raise ValueError(f"Completion without a recorded draw: {key}")
            if key in completed:
                raise ValueError(f"Duplicate completion: {key}")
            origin = origins[key]
            stamp = timing["presentation_time_us"]
            if origin["view"] != event["view"]:
                raise ValueError(f"Completion belongs to a different view: {key}")
            if type(stamp) is not int or stamp < 0 or type(timing["expired"]) is not bool:
                raise ValueError(f"Invalid presentation feedback: {key}")
            if timing["expired"] and stamp != 0:
                raise ValueError(f"Expired feedback has a presentation timestamp: {key}")
            if stamp and not origin["sample_clock_us"] <= stamp <= collected:
                raise ValueError(f"Presentation timestamp outside sample/collection bounds: {key}")
            completed[key] = timing
    return completed


def _segments(frames):
    """A paused draw or a different playback/clock starts a new measurement."""
    segments = []
    current = None
    for frame in frames:
        if not frame["playing"]:
            current = None
            continue
        if current is None or run_key(current[-1]) != run_key(frame):
            current = []
            segments.append(current)
        current.append(frame)
    return segments


def _draw_intervals(frames):
    intervals = []
    filtered = []
    excluded = {"nonpositive_event_interval": 0, "nonadvancing_scene": 0,
                "scene_increment_at_least_50ms": 0, "event_interval_at_least_100ms": 0}
    for first, second in zip(frames, frames[1:]):
        elapsed = second["clock_us"] - first["clock_us"]
        if elapsed < 0:
            raise ValueError("Draw-event timestamps moved backwards within a playback segment")
        intervals.append(elapsed / 1000)
        scene_step = second["displayed_time"] - first["displayed_time"]
        if elapsed <= 0:
            excluded["nonpositive_event_interval"] += 1
        elif scene_step <= 0:
            excluded["nonadvancing_scene"] += 1
        elif scene_step >= .05:
            excluded["scene_increment_at_least_50ms"] += 1
        elif elapsed >= 100000:
            excluded["event_interval_at_least_100ms"] += 1
        else:
            filtered.append(elapsed / 1000)
    return intervals, filtered, excluded


def _presentations(frames, origins, completed):
    # Multiple draws can share a GTK frame. Attribute its completion to the
    # last recorded content, even when that content belongs to another run.
    selected = [frame for frame in frames if origins[frame_key(frame)] is frame]
    counts = {"positive_timestamp_frames": 0, "unavailable_timestamp_frames": 0,
              "expired_frames": 0, "missing_completion_frames": 0}
    unknown_prefix = [0]
    by_stamp = {}
    previous_stamp = 0
    for index, frame in enumerate(selected):
        timing = completed.get(frame_key(frame))
        known = timing is not None and timing["presentation_time_us"] > 0
        unknown_prefix.append(unknown_prefix[-1] + int(not known))
        if timing is None:
            counts["missing_completion_frames"] += 1
        elif timing["expired"]:
            counts["expired_frames"] += 1
        elif not known:
            counts["unavailable_timestamp_frames"] += 1
        else:
            counts["positive_timestamp_frames"] += 1
            stamp = timing["presentation_time_us"]
            if stamp < previous_stamp:
                raise ValueError("Presentation timestamps moved backwards within a playback segment")
            previous_stamp = stamp
            by_stamp[stamp] = index

    intervals = []
    unknown_spans = []
    presented = list(by_stamp.items())
    for (first_stamp, first_index), (second_stamp, second_index) in zip(presented, presented[1:]):
        interval = (second_stamp - first_stamp) / 1000
        if unknown_prefix[second_index + 1] != unknown_prefix[first_index]:
            unknown_spans.append(interval)
        else:
            intervals.append(interval)
    positive_rate = ((len(presented) - 1) * 1e6 / (presented[-1][0] - presented[0][0])
                     if len(presented) > 1 else None)
    complete = bool(selected) and counts["positive_timestamp_frames"] == len(selected)
    report = {
        "selected_frame_keys": len(selected),
        "superseded_draw_events": len(frames) - len(selected),
        **counts,
        "completed_frames": len(selected) - counts["missing_completion_frames"],
        "presented_frames": len(presented),
        "coalesced_presentation_frames": counts["positive_timestamp_frames"] - len(presented),
        "feedback_coverage": counts["positive_timestamp_frames"] / len(selected) if selected else None,
        "complete_feedback": complete,
        "presentation_interval_ms": distribution(intervals),
        "unknown_feedback_span_ms": distribution(unknown_spans),
        "unknown_feedback_span_count": len(unknown_spans),
        "observed_positive_fps": positive_rate,
        "presented_fps": positive_rate if complete else None,
    }
    return report, intervals, unknown_spans


def timing_report(records, views=("presentation", "presenter")):
    """Measure playing draws, retaining every within-segment event interval.

    Presentation feedback is attributed by frame-clock ID and counter, not by
    the playback state of the later receipt. Paused draws terminate a segment;
    they remain in the identity index so a later repaint can supersede a draw.
    """
    records = list(records)
    origins = {}
    frames_by_view = {}
    for event in records:
        if event.get("event") != "frame":
            continue
        previous = origins.get(frame_key(event))
        if previous is not None and previous["view"] != event["view"]:
            raise ValueError("A frame clock was reused by a different view")
        origins[frame_key(event)] = event
        frames_by_view.setdefault(event["view"], []).append(event)
    completed = _feedback(records, origins)
    report = {
        "selection": "Playing draws, separated at pauses and changes of view, clock or playback state",
        "percentiles": "p50 is the median; p95/p99 use sorted[min(n-1, floor(n*p))]",
        "draw_filter": {
            "event_interval_ms": "0 < interval < 100",
            "scene_increment_ms": "0 < increment < 50",
            "exclusion_counts": "First matching reason in the reported order; boundary pairs are separate",
        },
        "views": {},
    }
    for view in views:
        segments = _segments(frames_by_view.get(view, []))
        playing = [frame for segment in segments for frame in segment]
        all_intervals, all_filtered, all_presented, all_unknown = [], [], [], []
        all_excluded = _draw_intervals([])[2]
        totals = {key: 0 for key in (
            "selected_frame_keys", "superseded_draw_events", "positive_timestamp_frames",
            "unavailable_timestamp_frames", "expired_frames", "missing_completion_frames",
            "completed_frames", "presented_frames", "coalesced_presentation_frames")}
        runs = []
        for segment in segments:
            intervals, filtered, excluded = _draw_intervals(segment)
            presentation, known_intervals, unknown_spans = _presentations(segment, origins, completed)
            for name in totals:
                totals[name] += presentation[name]
            for name in all_excluded:
                all_excluded[name] += excluded[name]
            all_intervals.extend(intervals)
            all_filtered.extend(filtered)
            all_presented.extend(known_intervals)
            all_unknown.extend(unknown_spans)
            first = segment[0]
            runs.append({
                **{name: first[name] for name in ("scene", "page", "frame_clock_id", "playback_id",
                                                 "speed", "anchor_time", "target")},
                "first_event_us": first["clock_us"], "last_event_us": segment[-1]["clock_us"],
                "draw_events": len(segment), "draw_event_interval_ms": distribution(intervals),
                "filtered_draw_event_interval_ms": distribution(filtered),
                "excluded_draw_pairs": excluded, "presentation": presentation,
            })
        total_keys = totals["selected_frame_keys"]
        cpu = [frame["render_cpu_us"] / 1000 for frame in playing if frame["render_cpu_us"] >= 0]
        wall = [frame["render_us"] / 1000 for frame in playing]
        if not all(math.isfinite(value) and value >= 0 for value in wall + cpu):
            raise ValueError("Invalid rendering duration")
        report["views"][view] = {
            "draw_events": len(playing), "playback_segments": len(segments),
            "candidate_draw_pairs": max(0, len(playing) - 1),
            "boundary_pairs": max(0, len(segments) - 1),
            "within_segment_pairs": len(all_intervals),
            "draw_event_interval_ms": distribution(all_intervals),
            "filtered_draw_event_interval_ms": distribution(all_filtered),
            "filtered_draw_intervals_under_20ms": sum(value < 20 for value in all_filtered),
            "excluded_draw_pairs": all_excluded,
            "render_wall_ms": distribution(wall), "render_cpu_ms": distribution(cpu),
            "unavailable_cpu_draws": len(playing) - len(cpu),
            "presentation": {
                **totals,
                "feedback_coverage": totals["positive_timestamp_frames"] / total_keys if total_keys else None,
                "complete_feedback": bool(total_keys) and totals["positive_timestamp_frames"] == total_keys,
                "presentation_interval_ms": distribution(all_presented),
                "unknown_feedback_span_ms": distribution(all_unknown),
                "unknown_feedback_span_count": len(all_unknown),
            },
            "runs": runs,
        }
    return report

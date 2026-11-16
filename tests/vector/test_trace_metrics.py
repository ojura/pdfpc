#!/usr/bin/env python3
"""Check draw cadence and partial presentation feedback without a display."""
from __future__ import annotations

import copy
import json
import unittest

from trace_metrics import distribution, timing_report


def frame(counter, stamp, *, position=None, run=900000, clock=1,
          view="presentation", playing=True, speed=1, **changes):
    result = dict(event="frame", frame_counter=counter, frame_clock_id=clock,
                  view=view, page=2, scene="example", playback_id=run,
                  clock_us=stamp, sample_clock_us=stamp - 10, playing=playing,
                  anchor_clock_us=run, anchor_time=0, speed=speed, target=3,
                  displayed_time=(stamp - run) / 1e6 * speed if position is None else position,
                  render_us=2000, render_cpu_us=1500)
    result.update(changes)
    return result


def receipt(*items, clock=1, view="presentation", collected=5000000):
    # Feedback arrives after navigation; attribution must use the draw's state.
    return dict(event="timing", clock_us=collected - 100, feedback_collected_us=collected,
                frame_clock_id=clock, view=view, page=9, scene="later", playback_id=4000000,
                completed_timings=[dict(counter=counter, presentation_time_us=stamp, expired=False)
                                   for counter, stamp in items])


class TraceMetrics(unittest.TestCase):
    def metrics(self, events, view="presentation"):
        result = timing_report(events)
        json.dumps(result, allow_nan=False)
        return result["views"][view]

    def test_empty_trace_has_explicit_empty_distributions(self):
        result = self.metrics([])
        self.assertEqual(result["candidate_draw_pairs"], 0)
        self.assertIsNone(result["draw_event_interval_ms"])
        self.assertIsNone(result["filtered_draw_event_interval_ms"])
        self.assertIsNone(result["presentation"]["feedback_coverage"])
        self.assertFalse(result["presentation"]["complete_feedback"])
        self.assertEqual(result["runs"], [])

    def test_percentiles_and_median_are_defined_for_small_samples(self):
        self.assertIsNone(distribution([]))
        self.assertEqual(distribution([4]), {"count": 1, "mean": 4, "p50": 4,
                                            "p95": 4, "p99": 4, "max": 4})
        self.assertEqual(distribution([4, 2])["p50"], 3)
        self.assertEqual(distribution(list(range(100)))["p95"], 95)
        self.assertEqual(distribution(list(range(100)))["p99"], 99)

    def test_draw_events_are_not_presentation_timestamps(self):
        events = [frame(1, 1000000), frame(2, 1010000),
                  receipt((1, 1001000), (2, 1034000))]
        result = self.metrics(events)
        self.assertEqual(result["draw_event_interval_ms"]["p50"], 10)
        self.assertEqual(result["filtered_draw_event_interval_ms"]["p50"], 10)
        self.assertEqual(result["presentation"]["presentation_interval_ms"]["p50"], 33)
        self.assertEqual(result["presentation"]["positive_timestamp_frames"], 2)
        self.assertAlmostEqual(result["runs"][0]["presentation"]["presented_fps"], 1000/33)

    def test_different_playback_runs_are_not_paired(self):
        events = [frame(1, 1000000, position=0),
                  frame(2, 1010000, position=.01, run=1010000),
                  receipt((1, 1001000), (2, 1011000))]
        result = self.metrics(events)
        self.assertEqual(result["candidate_draw_pairs"], 1)
        self.assertEqual(result["boundary_pairs"], 1)
        self.assertEqual(result["within_segment_pairs"], 0)
        self.assertIsNone(result["presentation"]["presentation_interval_ms"])
        self.assertEqual(len(result["runs"]), 2)

    def test_paused_draw_splits_a_reused_playback_id(self):
        result = self.metrics([frame(1, 1000000), frame(2, 1005000, playing=False),
                               frame(3, 1010000)])
        self.assertEqual(result["draw_events"], 2)
        self.assertEqual(result["playback_segments"], 2)
        self.assertEqual(result["boundary_pairs"], 1)
        self.assertIsNone(result["draw_event_interval_ms"])

    def test_clock_page_scene_and_speed_changes_split_segments(self):
        for change in ({"clock": 2}, {"page": 3}, {"scene": "another"}, {"speed": .5}):
            with self.subTest(change=change):
                result = self.metrics([frame(1, 1000000), frame(2, 1010000, **change)])
                self.assertEqual(result["boundary_pairs"], 1)
                self.assertEqual(result["within_segment_pairs"], 0)

    def test_long_draw_intervals_remain_in_unfiltered_report(self):
        result = self.metrics([frame(1, 1000000, position=0),
                               frame(2, 1120000, position=.03)])
        self.assertEqual(result["draw_event_interval_ms"]["max"], 120)
        self.assertIsNone(result["filtered_draw_event_interval_ms"])
        self.assertEqual(result["excluded_draw_pairs"]["event_interval_at_least_100ms"], 1)

    def test_filter_reasons_partition_excluded_pairs(self):
        cases = [(0, 0, "nonpositive_event_interval"),
                 (10000, 0, "nonadvancing_scene"),
                 (10000, .05, "scene_increment_at_least_50ms"),
                 (100000, .01, "event_interval_at_least_100ms")]
        for elapsed, position, reason in cases:
            with self.subTest(reason=reason):
                result = self.metrics([frame(1, 1000000, position=0),
                                       frame(2, 1000000 + elapsed, position=position)])
                self.assertEqual(result["within_segment_pairs"], 1)
                self.assertEqual(result["excluded_draw_pairs"][reason], 1)
                self.assertEqual(sum(result["excluded_draw_pairs"].values()), 1)
                self.assertIsNone(result["filtered_draw_event_interval_ms"])

    def test_boundary_and_filter_counts_account_for_all_candidates(self):
        result = self.metrics([frame(1, 1000000, position=0), frame(2, 1010000, position=.01),
                               frame(3, 1130000, position=.02),
                               frame(4, 1140000, position=.03, run=1140000)])
        retained = result["filtered_draw_event_interval_ms"]["count"]
        self.assertEqual(result["candidate_draw_pairs"],
                         result["boundary_pairs"] + retained + sum(result["excluded_draw_pairs"].values()))
        self.assertEqual(result["draw_event_interval_ms"]["count"], 2)

    def test_counter_collisions_between_views_are_independent(self):
        events = [frame(1, 1000000), frame(2, 1010000),
                  frame(1, 1001000, clock=2, view="presenter"),
                  frame(2, 1021000, clock=2, view="presenter"),
                  receipt((1, 1002000), (2, 1012000)),
                  receipt((1, 1003000), (2, 1023000), clock=2, view="presenter")]
        result = timing_report(events)["views"]
        self.assertEqual(result["presentation"]["presentation"]["presentation_interval_ms"]["mean"], 10)
        self.assertEqual(result["presenter"]["presentation"]["presentation_interval_ms"]["mean"], 20)

    def test_delayed_receipt_is_attributed_to_originating_draw(self):
        events = [frame(1, 1000000), frame(2, 1010000), receipt((1, 1001000), (2, 1011000))]
        result = self.metrics(events)
        run = result["runs"][0]
        self.assertEqual((run["scene"], run["page"], run["playback_id"]), ("example", 2, 900000))
        self.assertEqual(run["presentation"]["feedback_coverage"], 1)
        self.assertEqual(run["presentation"]["presentation_interval_ms"]["max"], 10)

    def test_equal_presentation_timestamps_count_one_refresh(self):
        events = [frame(1, 1000000), frame(2, 1010000), frame(3, 1020000),
                  receipt((1, 1001000), (2, 1031000), (3, 1031000))]
        report = self.metrics(events)["presentation"]
        self.assertEqual(report["positive_timestamp_frames"], 3)
        self.assertEqual(report["presented_frames"], 2)
        self.assertEqual(report["coalesced_presentation_frames"], 1)
        self.assertEqual(report["presentation_interval_ms"]["count"], 1)
        self.assertEqual(report["presentation_interval_ms"]["max"], 30)
        self.assertEqual(report["unknown_feedback_span_count"], 0)

    def test_unknown_middle_feedback_is_not_a_measured_stall(self):
        for kind in ("missing", "unavailable", "expired"):
            with self.subTest(kind=kind):
                frames = [frame(1, 1000000), frame(2, 1010000), frame(3, 1020000)]
                feedback = receipt((1, 1001000), (3, 1131000))
                if kind != "missing":
                    feedback["completed_timings"].append(dict(counter=2, presentation_time_us=0,
                                                              expired=kind == "expired"))
                result = self.metrics(frames + [feedback])
                report = result["presentation"]
                self.assertIsNone(report["presentation_interval_ms"])
                self.assertEqual(report["unknown_feedback_span_count"], 1)
                self.assertEqual(report["unknown_feedback_span_ms"]["max"], 130)
                self.assertAlmostEqual(report["feedback_coverage"], 2/3)
                self.assertFalse(report["complete_feedback"])
                run = result["runs"][0]["presentation"]
                self.assertIsNone(run["presented_fps"])
                self.assertAlmostEqual(run["observed_positive_fps"], 1000/130)
                counters = {"missing": "missing_completion_frames", "unavailable": "unavailable_timestamp_frames",
                            "expired": "expired_frames"}
                self.assertEqual(report[counters[kind]], 1)
                self.assertEqual(sum(report[name] for name in counters.values()), 1)

    def test_missing_endpoint_preserves_other_known_intervals(self):
        result = self.metrics([frame(1, 1000000), frame(2, 1010000), frame(3, 1020000),
                               receipt((1, 1001000), (2, 1011000))])
        self.assertEqual(result["presentation"]["presentation_interval_ms"]["max"], 10)
        self.assertEqual(result["presentation"]["missing_completion_frames"], 1)
        self.assertEqual(result["presentation"]["unknown_feedback_span_count"], 0)
        self.assertIsNone(result["runs"][0]["presentation"]["presented_fps"])

    def test_slow_known_presentations_are_not_filtered_out(self):
        report = self.metrics([frame(1, 1000000), frame(2, 1010000),
                               receipt((1, 1001000), (2, 1201000))])["presentation"]
        self.assertEqual(report["presentation_interval_ms"]["max"], 200)
        self.assertEqual(report["feedback_coverage"], 1)

    def test_duplicate_draw_uses_latest_content_and_counts_every_render(self):
        result = self.metrics([frame(1, 1000000), frame(1, 1005000), frame(2, 1010000),
                               receipt((1, 1006000), (2, 1011000))])
        self.assertEqual(result["draw_events"], 3)
        self.assertEqual(result["render_wall_ms"]["count"], 3)
        self.assertEqual(result["presentation"]["selected_frame_keys"], 2)
        self.assertEqual(result["presentation"]["superseded_draw_events"], 1)
        self.assertEqual(result["presentation"]["presentation_interval_ms"]["max"], 5)

    def test_same_frame_repainted_by_new_run_is_not_double_counted(self):
        result = self.metrics([frame(1, 1000000), frame(1, 1005000, run=1005000),
                               receipt((1, 1006000))])
        self.assertEqual(result["presentation"]["selected_frame_keys"], 1)
        self.assertEqual(result["presentation"]["positive_timestamp_frames"], 1)
        self.assertEqual(result["runs"][0]["presentation"]["selected_frame_keys"], 0)
        self.assertEqual(result["runs"][1]["presentation"]["selected_frame_keys"], 1)

    def test_paused_repaint_supersedes_playing_draw(self):
        result = self.metrics([frame(1, 1000000), frame(1, 1005000, playing=False),
                               receipt((1, 1006000))])
        self.assertEqual(result["draw_events"], 1)
        self.assertEqual(result["presentation"]["selected_frame_keys"], 0)
        self.assertIsNone(result["presentation"]["feedback_coverage"])

    def test_half_speed_keeps_wall_and_scene_time_distinct(self):
        result = self.metrics([frame(1, 1000000, speed=.5), frame(2, 1010000, speed=.5),
                               receipt((1, 1001000), (2, 1011000))])
        self.assertEqual(result["runs"][0]["speed"], .5)
        self.assertEqual(result["draw_event_interval_ms"]["mean"], 10)
        self.assertEqual(result["presentation"]["presentation_interval_ms"]["mean"], 10)
        self.assertEqual(result["runs"][0]["presentation"]["presented_fps"], 100)
        self.assertNotIn("scene_step_error_ms", result)

    def test_cpu_cost_and_unavailable_cpu_are_reported_separately(self):
        result = self.metrics([frame(1, 1000000), frame(2, 1010000, render_cpu_us=-1)])
        self.assertEqual(result["render_wall_ms"]["mean"], 2)
        self.assertEqual(result["render_cpu_ms"]["mean"], 1.5)
        self.assertEqual(result["unavailable_cpu_draws"], 1)

    def test_zero_timestamps_cannot_produce_a_delivery_rate(self):
        result = self.metrics([frame(1, 1000000), frame(2, 1010000), receipt((1, 0), (2, 0))])
        self.assertEqual(result["presentation"]["completed_frames"], 2)
        self.assertEqual(result["presentation"]["unavailable_timestamp_frames"], 2)
        self.assertEqual(result["presentation"]["feedback_coverage"], 0)
        self.assertIsNone(result["presentation"]["presentation_interval_ms"])
        self.assertIsNone(result["runs"][0]["presentation"]["observed_positive_fps"])
        self.assertIsNone(result["runs"][0]["presentation"]["presented_fps"])

    def test_feedback_timestamp_bounds_are_checked_after_the_actual_query(self):
        feedback = receipt((1, 1000500), collected=1000500)
        feedback["clock_us"] = 1000100
        result = self.metrics([frame(1, 1000000), feedback])
        self.assertEqual(result["presentation"]["positive_timestamp_frames"], 1)
        for stamp in (999989, 1000501):
            with self.subTest(stamp=stamp):
                bad = copy.deepcopy(feedback)
                bad["completed_timings"][0]["presentation_time_us"] = stamp
                with self.assertRaisesRegex(ValueError, "sample/collection bounds"):
                    self.metrics([frame(1, 1000000), bad])

    def test_invalid_completion_data_is_rejected(self):
        cases = []
        duplicate = receipt((1, 1001000), (1, 1001000))
        cases.append((duplicate, "Duplicate completion"))
        cases.append((receipt((2, 1001000)), "without a recorded draw"))
        wrong_view = receipt((1, 1001000), view="presenter")
        cases.append((wrong_view, "different view"))
        expired = receipt((1, 1001000))
        expired["completed_timings"][0]["expired"] = True
        cases.append((expired, "Expired feedback"))
        for feedback, message in cases:
            with self.subTest(message=message):
                with self.assertRaisesRegex(ValueError, message):
                    self.metrics([frame(1, 1000000), feedback])

    def test_invalid_collection_time_is_rejected_even_with_empty_feedback(self):
        for value in (None, True, 0, "5000000", 4999899):
            with self.subTest(value=value):
                feedback = receipt()
                feedback["feedback_collected_us"] = value
                with self.assertRaisesRegex(ValueError, "collection timestamp"):
                    self.metrics([feedback])

    def test_backwards_clocks_are_not_hidden_by_sorting(self):
        with self.assertRaisesRegex(ValueError, "Draw-event timestamps moved backwards"):
            self.metrics([frame(1, 1010000), frame(2, 1000000)])
        with self.assertRaisesRegex(ValueError, "Presentation timestamps moved backwards"):
            self.metrics([frame(1, 1000000), frame(2, 1010000),
                          receipt((1, 1030000), (2, 1020000))])


if __name__ == "__main__":
    unittest.main(verbosity=2)

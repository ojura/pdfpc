// SPDX-License-Identifier: GPL-3.0-or-later
// Optional trace I/O and delayed frame feedback are separate from playback.

namespace pdfpc {
    private class VectorTraceClock : Object {
        public Gdk.FrameClock clock;
        public int id;
        public string view;
        public int64 last_frame_counter = -1;
        public Gee.ArrayList<int64?> pending = new Gee.ArrayList<int64?>();

        public VectorTraceClock(Gdk.FrameClock clock, int id, string view) {
            this.clock = clock;
            this.id = id;
            this.view = view;
        }
    }

    internal class VectorTrace : Object {
        private GLib.WeakRef playback_ref;
        private string? trace_filename;
        private FileStream? trace_stream;
        private StringBuilder trace_buffer = new StringBuilder();
        // Events finish synchronously on the GTK thread before buffer reuse.
        private VectorTraceWriter? trace_writer;
        private Gee.HashMap<Gdk.FrameClock, VectorTraceClock> trace_clocks =
            new Gee.HashMap<Gdk.FrameClock, VectorTraceClock>();
        private uint trace_drain_id = 0;
        private int64 trace_drain_until = 0;
        private int64 last_frame_recorded_us = 0;
        private string trace_display_backend = "unknown";

        public bool enabled { get { return trace_stream != null; } }

        public VectorTrace(VectorPlayback playback) {
            playback_ref = GLib.WeakRef(playback);
            trace_filename = Environment.get_variable("PDFPC_VECTOR_TRACE");
            if (trace_filename == null || trace_filename == "") return;
            trace_stream = FileStream.open(trace_filename, "a");
            if (trace_stream == null) {
                printerr("Cannot open vector trace: %s\n", trace_filename);
            } else {
                var display = Gdk.Display.get_default();
                if (display != null) trace_display_backend = display.get_type().name();
            }
        }

        public void close() {
            stop_collector();
            if (!enabled) return;
            var state = playback_ref.get() as VectorPlayback;
            if (state == null) {
                flush_trace();
                release_sink();
                return;
            }
            int pending = 0;
            foreach (var trace in trace_clocks.values) {
                if (trace.pending.size == 0) continue;
                unowned VectorTraceWriter builder = event_builder("timing", state);
                builder.add_string("view", trace.view);
                append_completed_timings(builder, trace);
                if (!write_trace(builder)) return;
                pending += trace.pending.size;
            }
            unowned VectorTraceWriter builder = event_builder("trace-closed", state);
            builder.add_int("pending_frames", pending);
            builder.add_int("last_frame_recorded_us", last_frame_recorded_us);
            write_trace(builder, false, true);
            release_sink();
        }

        ~VectorTrace() { release_sink(); }

        private unowned VectorTraceWriter event_builder(string kind, VectorPlayback state) {
            if (trace_writer == null) trace_writer = new VectorTraceWriter();
            unowned VectorTraceWriter builder = trace_writer;
            builder.begin_event(kind, GLib.get_monotonic_time());
            builder.add_int("page", state.page + 1);
            builder.add_string("scene", state.binding == null ? null : state.binding.scene.id);
            builder.add_double("time", state.time);
            builder.add_bool("playing", state.playing);
            builder.add_int("playback_id", state.playback_anchor_clock);
            builder.add_int("anchor_clock_us", state.playback_anchor_clock);
            builder.add_double("anchor_time", state.playback_anchor_time);
            builder.add_double("speed", state.speed);
            builder.add_double("target", state.playback_target);
            builder.add_string("display_backend", trace_display_backend);
            return builder;
        }

        private void stop_collector() {
            if (trace_drain_id == 0) return;
            uint id = trace_drain_id;
            trace_drain_id = 0;
            Source.remove(id);
        }

        private void release_sink() {
            stop_collector();
            trace_stream = null;
            trace_buffer.truncate(0);
            trace_clocks.clear();
        }

        private bool flush_trace() {
            if (trace_stream == null) return false;
            if (trace_buffer.len == 0) return true;
            if (trace_stream.puts(trace_buffer.str) < 0 || trace_stream.flush() != 0) {
                int error_number = Posix.errno;
                // Drop the failed sink and its collector, not lecture state.
                // Keep the event writer alive for an explicit stdout status.
                release_sink();
                printerr("Cannot write vector trace '%s': %s\n", trace_filename,
                    error_number == 0 ? "I/O error" : GLib.strerror(error_number));
                return false;
            }
            trace_buffer.truncate(0);
            return true;
        }

        private bool write_trace(VectorTraceWriter builder, bool stdout_too = false,
            bool flush = false) {
            builder.finish();
            bool written = enabled;
            if (enabled) {
                trace_buffer.append(builder.data);
                trace_buffer.append_c('\n');
                if (flush || trace_buffer.len >= 256*1024) written = flush_trace();
            }
            if (stdout_too) print("%s\n", builder.data);
            return written;
        }

        private void append_completed_timings(VectorTraceWriter builder, VectorTraceClock trace) {
            builder.add_int("frame_clock_id", trace.id);
            builder.begin_timings();
            for (int i = 0; i < trace.pending.size;) {
                // Name the owned nullable value so Vala releases get()'s boxed copy.
                int64? pending_counter = trace.pending.get(i);
                int64 counter = (int64) pending_counter;
                var timing = trace.clock.get_timings(counter);
                bool expired = counter < trace.clock.get_history_start();
                if (expired || (timing != null && timing.get_complete())) {
                    builder.add_timing(counter, expired ? 0 : timing.get_presentation_time(), expired);
                    trace.pending.remove_at(i);
                } else {
                    i++;
                }
            }
            int64 collected = GLib.get_monotonic_time();
            builder.end_timings();
            builder.add_int("feedback_collected_us", collected);
        }

        private bool collect_stopped() {
            var state = playback_ref.get() as VectorPlayback;
            if (!enabled || state == null || state.playing) {
                trace_drain_id = 0;
                if (state == null) release_sink();
                return false;
            }
            int pending = 0;
            foreach (var trace in trace_clocks.values) {
                if (trace.pending.size == 0) continue;
                unowned VectorTraceWriter builder = event_builder("timing", state);
                builder.add_string("view", trace.view);
                append_completed_timings(builder, trace);
                // A failed write clears clock tracking. Do not advance its iterator.
                if (!write_trace(builder)) return false;
                pending += trace.pending.size;
            }
            if (pending == 0 || GLib.get_monotonic_time() >= trace_drain_until) {
                trace_drain_id = 0;
                unowned VectorTraceWriter builder = event_builder("trace-drained", state);
                builder.add_int("pending_frames", pending);
                builder.add_int("last_frame_recorded_us", last_frame_recorded_us);
                write_trace(builder, false, true);
                return false;
            }
            return flush_trace();
        }

        private void schedule_trace_drain() {
            if (!enabled || trace_clocks.size == 0) return;
            trace_drain_until = GLib.get_monotonic_time() + 500000;
            if (trace_drain_id != 0) return;
            // The source retains only diagnostics. Playback closes it on teardown;
            // WeakRef prevents this stopped collector from retaining playback.
            trace_drain_id = Timeout.add(20, collect_stopped);
        }

        public void trace_state(string reason, bool stdout_too = false) {
            if (trace_stream == null && !stdout_too) {
                return;
            }
            var state = playback_ref.get() as VectorPlayback;
            if (state == null) return;
            unowned VectorTraceWriter builder = event_builder("state", state);
            builder.add_string("reason", reason);
            builder.add_int("checkpoint", state.binding == null ? -1 : state.binding.scene.checkpoint_at(state.time));
            write_trace(builder, stdout_too, true);
            if (!state.playing) schedule_trace_drain();
        }

        public int64 diagnostic_cpu_time() {
#if THREAD_CPU_CLOCK
            if (trace_stream == null) return -1;
            Posix.timespec stamp;
            if (Posix.clock_gettime(Posix.CLOCK_THREAD_CPUTIME_ID, out stamp) != 0) return -1;
            return (int64) stamp.tv_sec*1000000 + stamp.tv_nsec/1000;
#else
            return -1;
#endif
        }

        public void record_frame(string view, double displayed_time, int64 sample_clock_us, int64 render_us,
            int64 render_cpu_us, int width, int height, Gdk.FrameClock? clock,
            Cairo.SurfaceType target_type, Cairo.SurfaceType group_target_type) {
            if (trace_stream == null) {
                return;
            }
            var state = playback_ref.get() as VectorPlayback;
            if (state == null) return;
            unowned VectorTraceWriter builder = event_builder("frame", state);
            builder.add_string("view", view);
            builder.add_double("displayed_time", displayed_time);
            builder.add_int("sample_clock_us", sample_clock_us);
            builder.add_int("render_us", render_us);
            builder.add_int("render_cpu_us", render_cpu_us);
            builder.add_int("width", width);
            builder.add_int("height", height);
            builder.add_int("cairo_target_type", (int) target_type);
            builder.add_int("cairo_group_target_type", (int) group_target_type);
            if (clock != null) {
                var trace = trace_clocks.get(clock);
                if (trace == null) {
                    trace = new VectorTraceClock(clock, trace_clocks.size + 1, view);
                    trace_clocks.set(clock, trace);
                }
                int64 counter = clock.get_frame_counter();
                builder.add_int("frame_counter", counter);
                builder.add_int("frame_time_us", clock.get_frame_time());
                int64 refresh_interval, predicted_presentation;
                clock.get_refresh_info(clock.get_frame_time(), out refresh_interval,
                    out predicted_presentation);
                builder.add_int("refresh_interval_us", refresh_interval);
                append_completed_timings(builder, trace);
                if (counter != trace.last_frame_counter) {
                    trace.pending.add(counter);
                    trace.last_frame_counter = counter;
                }
            }
            last_frame_recorded_us = GLib.get_monotonic_time();
            write_trace(builder, false, !state.playing);
            if (!state.playing) schedule_trace_drain();
        }

        public void record_work(string name, string view, int work_page,
            int64 started_us, int64 wall_us, int64 cpu_us) {
            if (trace_stream == null) return;
            var state = playback_ref.get() as VectorPlayback;
            if (state == null) return;
            unowned VectorTraceWriter builder = event_builder("work", state);
            builder.add_string("work", name);
            builder.add_string("view", view);
            builder.add_int("work_page", work_page + 1);
            builder.add_int("started_us", started_us);
            builder.add_int("wall_us", wall_us);
            builder.add_int("cpu_us", cpu_us);
            write_trace(builder, false, !state.playing);
        }
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
// One monotonic anchor serves both views; display frame clocks schedule redraws.

namespace pdfpc {
    public class VectorBinding : Object {
        public VectorScene scene;
        public Poppler.Rectangle area;
        public int page;
        public double full_width;
        public double full_height;

        public VectorBinding(VectorScene scene, Poppler.Rectangle area, int page,
            double full_width, double full_height) {
            this.scene = scene;
            this.area = area;
            this.page = page;
            this.full_width = full_width;
            this.full_height = full_height;
        }

        public void draw(Cairo.Context cr, Metadata.Pdf metadata, double time,
            int width, int height, PresentationController.ScaledRectangle? zoom_area) {
            cr.save();
            Renderer.Pdf.apply_page_transform(cr, metadata, full_width, full_height,
                false, width, height, zoom_area);
            double box_width = area.x2 - area.x1;
            double box_height = area.y2 - area.y1;
            cr.rectangle(area.x1, full_height - area.y2, box_width, box_height);
            cr.clip();
            cr.translate(area.x1, full_height - area.y2);
            scene.draw_fitted(cr, time, box_width, box_height);
            cr.restore();
        }
    }

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

    public class VectorPlayback : Object {
        public const string URI_PREFIX = "pdfpc-vector:";
        private weak PresentationController controller;
        private VectorDeck? deck;
        private Gee.HashMap<int, VectorBinding> bindings = new Gee.HashMap<int, VectorBinding>();
        public VectorBinding? binding { get; private set; default = null; }
        public int page { get; private set; default = -1; }
        public double time { get; private set; default = 0; }
        public double speed { get; private set; default = 1; }
        public bool playing { get; private set; default = false; }
        public signal void started();
        private double target = 0;
        private double anchor_time = 0;
        private int64 anchor_clock = 0;
        private FileStream? trace_stream;
        private StringBuilder trace_buffer = new StringBuilder();
        // GTK-thread producers complete each event synchronously before reuse.
        private VectorTraceWriter? trace_writer;
        private Gee.HashMap<Gdk.FrameClock, VectorTraceClock> trace_clocks =
            new Gee.HashMap<Gdk.FrameClock, VectorTraceClock>();
        private uint trace_drain_id = 0;
        private int64 trace_drain_until = 0;
        private int64 last_frame_recorded_us = 0;
        private string trace_display_backend = "unknown";

        public bool tracing_enabled { get { return trace_stream != null; } }

        public VectorPlayback(PresentationController controller) {
            this.controller = controller;
            string? trace_filename = Environment.get_variable("PDFPC_VECTOR_TRACE");
            if (trace_filename != null && trace_filename != "") {
                trace_stream = FileStream.open(trace_filename, "a");
                if (trace_stream == null) {
                    printerr("Cannot open vector trace: %s\n", trace_filename);
                } else {
                    var display = Gdk.Display.get_default();
                    if (display != null) trace_display_backend = display.get_type().name();
                }
            }
            string? speed_text = Environment.get_variable("PDFPC_VECTOR_SPEED");
            double requested_speed = 1;
            if (speed_text != null && double.try_parse(speed_text, out requested_speed) &&
                requested_speed >= 0.1 && requested_speed <= 8) {
                speed = requested_speed;
            }
            reload();
        }

        public void close_trace() {
            if (trace_stream == null) return;
            if (trace_drain_id != 0) {
                Source.remove(trace_drain_id);
                trace_drain_id = 0;
            }
            int pending = 0;
            foreach (var trace in trace_clocks.values) {
                if (trace.pending.size == 0) continue;
                unowned VectorTraceWriter builder = event_builder("timing");
                builder.add_string("view", trace.view);
                append_completed_timings(builder, trace);
                write_trace(builder);
                pending += trace.pending.size;
            }
            unowned VectorTraceWriter builder = event_builder("trace-closed");
            builder.add_int("pending_frames", pending);
            builder.add_int("last_frame_recorded_us", last_frame_recorded_us);
            write_trace(builder, false, true);
            trace_stream = null;
        }

        ~VectorPlayback() {
            close_trace();
        }

        public void reload() {
            playing = false;
            deck = null;
            bindings.clear();
            binding = null;
            page = -1;
            string? source = Environment.get_variable("PDFPC_VECTOR_MANIFEST");
            if (source == null || source == "") {
                string? pdf = controller.metadata.pdf_fname;
                if (pdf == null) {
                    return;
                }
                source = pdf.has_suffix(".pdf") ? pdf.substring(0, pdf.length - 4) + ".vector.json" :
                    pdf + ".vector.json";
                if (!FileUtils.test(source, FileTest.IS_REGULAR)) {
                    return;
                }
            }
            try {
                deck = new VectorDeck(source);
                var metadata = controller.metadata;
                for (int index = 0; index < metadata.get_slide_count(); index++) {
                    var pdf_page = metadata.document.get_page(index);
                    double width, height;
                    pdf_page.get_size(out width, out height);
                    foreach (var mapping in pdf_page.get_link_mapping()) {
                        if (mapping.action.type != Poppler.ActionType.URI ||
                            !mapping.action.uri.uri.has_prefix(URI_PREFIX)) {
                            continue;
                        }
                        string id = mapping.action.uri.uri.substring(URI_PREFIX.length);
                        var scene = deck.find(id);
                        if (scene == null) {
                            printerr("Vector scene '%s' on PDF page %d is missing from %s\n",
                                id, index + 1, source);
                            continue;
                        }
                        if (bindings.has_key(index)) {
                            printerr("PDF page %d has more than one vector region; using its first region\n",
                                index + 1);
                            continue;
                        }
                        if (mapping.area.x2 <= mapping.area.x1 || mapping.area.y2 <= mapping.area.y1) {
                            printerr("PDF page %d has an empty vector region\n", index + 1);
                            continue;
                        }
                        bindings.set(index, new VectorBinding(scene, mapping.area, index, width, height));
                    }
                }
                print("Vector timelines: %d scenes, %d PDF regions (%s)\n",
                    deck.scenes.size, bindings.size, source);
            } catch (GLib.Error error) {
                printerr("Cannot load vector timeline '%s': %s\n", source, error.message);
                deck = null;
                bindings.clear();
            }
            select_page(controller.current_slide_number);
        }

        public VectorBinding? binding_for(int page) {
            return bindings.get(page);
        }

        public void select_page(int page, bool backwards = false) {
            if (page == this.page) {
                return;
            }
            playing = false;
            this.page = page;
            binding = binding_for(page);
            time = backwards && binding != null ? binding.scene.duration : 0;
            target = time;
            changed("page");
        }

        private void changed(string reason) {
            trace_state(reason);
            controller.vector_changed();
        }

        private void run_to(double end) {
            if (!can_play() || end <= time + 1e-6) {
                return;
            }
            target = double.min(end, binding.scene.duration);
            anchor_time = time;
            anchor_clock = GLib.get_monotonic_time();
            playing = true;
            started();
            changed("play");
        }

        public double time_at(int64 clock_time) {
            if (!playing) return time;
            double elapsed = double.max(0, (clock_time - anchor_clock)/1000000.0);
            return double.min(target, anchor_time + elapsed*speed);
        }

        public void advance(int64 clock_time) {
            if (!playing) {
                return;
            }
            int previous_checkpoint = binding.scene.checkpoint_at(time);
            time = time_at(clock_time);
            if (time >= target - 1e-7) {
                time = target;
                playing = false;
                changed("checkpoint");
            } else if (binding.scene.checkpoint_at(time) != previous_checkpoint) {
                changed("checkpoint-passed");
            }
        }

        public void pause() {
            if (!playing) {
                return;
            }
            advance(GLib.get_monotonic_time());
            playing = false;
            changed("pause");
        }

        public void seek(double position) {
            if (binding == null) {
                return;
            }
            playing = false;
            time = double.min(binding.scene.duration, double.max(0, position));
            target = time;
            changed("seek");
        }

        public bool next() {
            if (!can_play()) {
                return false;
            }
            if (playing) {
                next_checkpoint();
                return true;
            }
            foreach (var step in binding.scene.checkpoints) {
                if (step.time > time + 1e-6) {
                    run_to(step.time);
                    return true;
                }
            }
            return false;
        }

        public void next_checkpoint() {
            if (binding == null) return;
            if (playing) advance(GLib.get_monotonic_time());
            foreach (var step in binding.scene.checkpoints) {
                if (step.time > time + 1e-6) {
                    seek(step.time);
                    return;
                }
            }
            seek(binding.scene.duration);
        }

        public void previous_checkpoint() {
            if (binding == null) return;
            if (playing) advance(GLib.get_monotonic_time());
            if (!previous()) seek(0);
        }

        public bool previous() {
            if (binding == null || time <= 1e-6) {
                return false;
            }
            var steps = binding.scene.checkpoints;
            for (int i = steps.length - 1; i >= 0; i--) {
                if (steps[i].time < time - 1e-6) {
                    seek(steps[i].time);
                    return true;
                }
            }
            seek(0);
            return true;
        }

        public void toggle() {
            if (playing) {
                pause();
            } else {
                if (!can_play()) return;
                if (binding != null && time >= binding.scene.duration - 1e-6) {
                    seek(0);
                }
                if (target > time + 1e-6) run_to(target);
                else next();
            }
        }

        public void play_all() {
            if (can_play()) {
                if (time >= binding.scene.duration - 1e-6) {
                    seek(0);
                }
                run_to(binding.scene.duration);
            }
        }

        public void change_speed(double factor) {
            if (playing) {
                advance(GLib.get_monotonic_time());
            }
            speed = double.min(8, double.max(0.1, speed*factor));
            anchor_time = time;
            anchor_clock = GLib.get_monotonic_time();
            changed("speed");
        }

        public bool can_play() {
            return binding != null && !controller.frozen && !controller.faded_to_black &&
                !controller.hidden && !controller.overview_shown;
        }

        public string status_text() {
            if (binding == null) {
                return "";
            }
            var scene = binding.scene;
            int current = scene.checkpoint_at(time);
            return "%d/%d  %s  (%s, %g×)".printf(current + 1, scene.checkpoints.length,
                scene.checkpoints[current].label, playing ? "playing" : "paused", speed);
        }

        private unowned VectorTraceWriter event_builder(string kind) {
            if (trace_writer == null) trace_writer = new VectorTraceWriter();
            unowned VectorTraceWriter builder = trace_writer;
            builder.begin_event(kind, GLib.get_monotonic_time());
            builder.add_int("page", page + 1);
            builder.add_string("scene", binding == null ? null : binding.scene.id);
            builder.add_double("time", time);
            builder.add_bool("playing", playing);
            builder.add_int("playback_id", anchor_clock);
            builder.add_int("anchor_clock_us", anchor_clock);
            builder.add_double("anchor_time", anchor_time);
            builder.add_double("speed", speed);
            builder.add_double("target", target);
            builder.add_string("display_backend", trace_display_backend);
            return builder;
        }

        private void flush_trace() {
            if (trace_stream != null && trace_buffer.len > 0) {
                trace_stream.puts(trace_buffer.str);
                trace_stream.flush();
                trace_buffer.truncate(0);
            }
        }

        private void write_trace(VectorTraceWriter builder, bool stdout_too = false, bool flush = false) {
            builder.finish();
            if (trace_stream != null) {
                trace_buffer.append(builder.data);
                trace_buffer.append_c('\n');
                if (flush || trace_buffer.len >= 256*1024) flush_trace();
            }
            if (stdout_too) print("%s\n", builder.data);
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

        private void schedule_trace_drain() {
            if (trace_stream == null || trace_clocks.size == 0) return;
            trace_drain_until = GLib.get_monotonic_time() + 500000;
            if (trace_drain_id != 0) return;
            // Frame completion can arrive after the last draw. Poll only while
            // stopped, without requesting more draws or changing playback.
            trace_drain_id = Timeout.add(20, () => {
                if (playing) {
                    trace_drain_id = 0;
                    return false;
                }
                int pending = 0;
                foreach (var trace in trace_clocks.values) {
                    if (trace.pending.size == 0) continue;
                    unowned VectorTraceWriter builder = event_builder("timing");
                    builder.add_string("view", trace.view);
                    append_completed_timings(builder, trace);
                    write_trace(builder);
                    pending += trace.pending.size;
                }
                if (pending == 0 || GLib.get_monotonic_time() >= trace_drain_until) {
                    unowned VectorTraceWriter builder = event_builder("trace-drained");
                    builder.add_int("pending_frames", pending);
                    builder.add_int("last_frame_recorded_us", last_frame_recorded_us);
                    write_trace(builder, false, true);
                    trace_drain_id = 0;
                    return false;
                }
                flush_trace();
                return true;
            });
        }

        public void trace_state(string reason, bool stdout_too = false) {
            if (trace_stream == null && !stdout_too) {
                return;
            }
            unowned VectorTraceWriter builder = event_builder("state");
            builder.add_string("reason", reason);
            builder.add_int("checkpoint", binding == null ? -1 : binding.scene.checkpoint_at(time));
            write_trace(builder, stdout_too, true);
            if (!playing) schedule_trace_drain();
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
            unowned VectorTraceWriter builder = event_builder("frame");
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
            write_trace(builder, false, !playing);
            if (!playing) schedule_trace_drain();
        }

        public void record_work(string name, string view, int work_page,
            int64 started_us, int64 wall_us, int64 cpu_us) {
            if (trace_stream == null) return;
            unowned VectorTraceWriter builder = event_builder("work");
            builder.add_string("work", name);
            builder.add_string("view", view);
            builder.add_int("work_page", work_page + 1);
            builder.add_int("started_us", started_us);
            builder.add_int("wall_us", wall_us);
            builder.add_int("cpu_us", cpu_us);
            write_trace(builder, false, !playing);
        }
    }
}

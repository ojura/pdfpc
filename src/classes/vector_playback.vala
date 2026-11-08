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
            double page_width = metadata.get_corrected_page_width(full_width);
            double page_height = metadata.get_corrected_page_height(full_height);
            double scale = double.min(width/page_width, height/page_height);
            double x_offset = (width/scale - page_width)/2;
            double y_offset = (height/scale - page_height)/2;
            if (zoom_area != null) {
                double zoom = 1/double.max(zoom_area.width, zoom_area.height);
                double x_zoom = double.max(0, (zoom_area.height - zoom_area.width)/2);
                double y_zoom = double.max(0, (zoom_area.width - zoom_area.height)/2);
                x_offset -= page_width*(zoom_area.x - x_zoom);
                y_offset -= page_height*(zoom_area.y - y_zoom);
                scale *= zoom;
            }
            cr.save();
            cr.scale(scale, scale);
            cr.translate(x_offset - metadata.get_horizontal_offset(false, full_width),
                y_offset - metadata.get_vertical_offset(false, full_height));
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
        private double target = 0;
        private double anchor_time = 0;
        private int64 anchor_clock = 0;
        private FileStream? trace_stream;
        private StringBuilder trace_buffer = new StringBuilder();
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
                var builder = event_builder("timing");
                builder.set_member_name("view"); builder.add_string_value(trace.view);
                append_completed_timings(builder, trace);
                write_trace(builder);
                pending += trace.pending.size;
            }
            var builder = event_builder("trace-closed");
            builder.set_member_name("pending_frames"); builder.add_int_value(pending);
            builder.set_member_name("last_frame_recorded_us"); builder.add_int_value(last_frame_recorded_us);
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

        private Json.Builder event_builder(string kind) {
            var builder = new Json.Builder();
            builder.begin_object();
            builder.set_member_name("event"); builder.add_string_value(kind);
            builder.set_member_name("clock_us"); builder.add_int_value(GLib.get_monotonic_time());
            builder.set_member_name("page"); builder.add_int_value(page + 1);
            builder.set_member_name("scene");
            if (binding == null) builder.add_null_value();
            else builder.add_string_value(binding.scene.id);
            builder.set_member_name("time"); builder.add_double_value(time);
            builder.set_member_name("playing"); builder.add_boolean_value(playing);
            builder.set_member_name("playback_id"); builder.add_int_value(anchor_clock);
            builder.set_member_name("anchor_clock_us"); builder.add_int_value(anchor_clock);
            builder.set_member_name("anchor_time"); builder.add_double_value(anchor_time);
            builder.set_member_name("speed"); builder.add_double_value(speed);
            builder.set_member_name("target"); builder.add_double_value(target);
            builder.set_member_name("display_backend"); builder.add_string_value(trace_display_backend);
            return builder;
        }

        private void flush_trace() {
            if (trace_stream != null && trace_buffer.len > 0) {
                trace_stream.puts(trace_buffer.str);
                trace_stream.flush();
                trace_buffer.truncate(0);
            }
        }

        private void write_trace(Json.Builder builder, bool stdout_too = false, bool flush = false) {
            builder.end_object();
            var generator = new Json.Generator();
            generator.set_root(builder.get_root());
            string data = generator.to_data(null);
            if (trace_stream != null) {
                trace_buffer.append(data);
                trace_buffer.append_c('\n');
                if (flush || trace_buffer.len >= 256*1024) flush_trace();
            }
            if (stdout_too) print("%s\n", data);
        }

        private void append_completed_timings(Json.Builder builder, VectorTraceClock trace) {
            builder.set_member_name("frame_clock_id"); builder.add_int_value(trace.id);
            builder.set_member_name("completed_timings"); builder.begin_array();
            for (int i = 0; i < trace.pending.size;) {
                int64 counter = (int64) trace.pending.get(i);
                var timing = trace.clock.get_timings(counter);
                bool expired = counter < trace.clock.get_history_start();
                if (expired || (timing != null && timing.get_complete())) {
                    builder.begin_object();
                    builder.set_member_name("counter"); builder.add_int_value(counter);
                    builder.set_member_name("presentation_time_us");
                    builder.add_int_value(expired ? 0 : timing.get_presentation_time());
                    builder.set_member_name("expired"); builder.add_boolean_value(expired);
                    builder.end_object();
                    trace.pending.remove_at(i);
                } else {
                    i++;
                }
            }
            builder.end_array();
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
                    var builder = event_builder("timing");
                    builder.set_member_name("view"); builder.add_string_value(trace.view);
                    append_completed_timings(builder, trace);
                    write_trace(builder);
                    pending += trace.pending.size;
                }
                if (pending == 0 || GLib.get_monotonic_time() >= trace_drain_until) {
                    var builder = event_builder("trace-drained");
                    builder.set_member_name("pending_frames"); builder.add_int_value(pending);
                    builder.set_member_name("last_frame_recorded_us"); builder.add_int_value(last_frame_recorded_us);
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
            var builder = event_builder("state");
            builder.set_member_name("reason"); builder.add_string_value(reason);
            builder.set_member_name("checkpoint");
            builder.add_int_value(binding == null ? -1 : binding.scene.checkpoint_at(time));
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
            var builder = event_builder("frame");
            builder.set_member_name("view"); builder.add_string_value(view);
            builder.set_member_name("displayed_time"); builder.add_double_value(displayed_time);
            builder.set_member_name("sample_clock_us"); builder.add_int_value(sample_clock_us);
            builder.set_member_name("render_us"); builder.add_int_value(render_us);
            builder.set_member_name("render_cpu_us"); builder.add_int_value(render_cpu_us);
            builder.set_member_name("width"); builder.add_int_value(width);
            builder.set_member_name("height"); builder.add_int_value(height);
            builder.set_member_name("cairo_target_type"); builder.add_int_value((int) target_type);
            builder.set_member_name("cairo_group_target_type"); builder.add_int_value((int) group_target_type);
            if (clock != null) {
                var trace = trace_clocks.get(clock);
                if (trace == null) {
                    trace = new VectorTraceClock(clock, trace_clocks.size + 1, view);
                    trace_clocks.set(clock, trace);
                }
                int64 counter = clock.get_frame_counter();
                builder.set_member_name("frame_counter"); builder.add_int_value(counter);
                builder.set_member_name("frame_time_us"); builder.add_int_value(clock.get_frame_time());
                int64 refresh_interval, predicted_presentation;
                clock.get_refresh_info(clock.get_frame_time(), out refresh_interval,
                    out predicted_presentation);
                builder.set_member_name("refresh_interval_us"); builder.add_int_value(refresh_interval);
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
            var builder = event_builder("work");
            builder.set_member_name("work"); builder.add_string_value(name);
            builder.set_member_name("view"); builder.add_string_value(view);
            builder.set_member_name("work_page"); builder.add_int_value(work_page + 1);
            builder.set_member_name("started_us"); builder.add_int_value(started_us);
            builder.set_member_name("wall_us"); builder.add_int_value(wall_us);
            builder.set_member_name("cpu_us"); builder.add_int_value(cpu_us);
            write_trace(builder, false, !playing);
        }
    }
}

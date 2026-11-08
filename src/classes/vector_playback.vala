// SPDX-License-Identifier: GPL-3.0-or-later
// One playback clock serves the presenter's current view and the audience view.

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
        private Gee.HashMap<Gdk.FrameClock, int64?> traced_counters =
            new Gee.HashMap<Gdk.FrameClock, int64?>();

        public VectorPlayback(PresentationController controller) {
            this.controller = controller;
            string? trace_filename = Environment.get_variable("PDFPC_VECTOR_TRACE");
            if (trace_filename != null && trace_filename != "") {
                trace_stream = FileStream.open(trace_filename, "a");
                if (trace_stream == null) {
                    printerr("Cannot open vector trace: %s\n", trace_filename);
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

        public void advance(int64 clock_time) {
            if (!playing) {
                return;
            }
            int previous_checkpoint = binding.scene.checkpoint_at(time);
            double elapsed = double.max(0, (clock_time - anchor_clock)/1000000.0);
            time = double.min(target, double.max(time, anchor_time + elapsed*speed));
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
            return builder;
        }

        private void write_trace(Json.Builder builder, bool stdout_too = false) {
            builder.end_object();
            var generator = new Json.Generator();
            generator.set_root(builder.get_root());
            string data = generator.to_data(null);
            if (trace_stream != null) {
                trace_stream.puts(data + "\n");
                trace_stream.flush();
            }
            if (stdout_too) print("%s\n", data);
        }

        public void trace_state(string reason, bool stdout_too = false) {
            if (trace_stream == null && !stdout_too) {
                return;
            }
            var builder = event_builder("state");
            builder.set_member_name("reason"); builder.add_string_value(reason);
            builder.set_member_name("speed"); builder.add_double_value(speed);
            builder.set_member_name("target"); builder.add_double_value(target);
            builder.set_member_name("checkpoint");
            builder.add_int_value(binding == null ? -1 : binding.scene.checkpoint_at(time));
            write_trace(builder, stdout_too);
        }

        public void record_frame(string view, double displayed_time, int64 render_us,
            int width, int height, Gdk.FrameClock? clock) {
            if (trace_stream == null) {
                return;
            }
            var builder = event_builder("frame");
            builder.set_member_name("view"); builder.add_string_value(view);
            builder.set_member_name("displayed_time"); builder.add_double_value(displayed_time);
            builder.set_member_name("render_us"); builder.add_int_value(render_us);
            builder.set_member_name("width"); builder.add_int_value(width);
            builder.set_member_name("height"); builder.add_int_value(height);
            if (clock != null) {
                int64 counter = clock.get_frame_counter();
                builder.set_member_name("frame_counter"); builder.add_int_value(counter);
                builder.set_member_name("frame_time_us"); builder.add_int_value(clock.get_frame_time());
                int64 refresh_interval, predicted_presentation;
                clock.get_refresh_info(clock.get_frame_time(), out refresh_interval,
                    out predicted_presentation);
                builder.set_member_name("refresh_interval_us"); builder.add_int_value(refresh_interval);
                int64 last_traced = traced_counters.has_key(clock) ?
                    (int64) traced_counters.get(clock) : clock.get_history_start() - 1;
                int64 newest = last_traced;
                builder.set_member_name("completed_timings"); builder.begin_array();
                for (int64 index = int64.max(last_traced + 1, clock.get_history_start());
                     index < counter; index++) {
                    var timing = clock.get_timings(index);
                    if (timing != null && timing.get_complete() && timing.get_presentation_time() > 0) {
                        builder.begin_object();
                        builder.set_member_name("counter"); builder.add_int_value(index);
                        builder.set_member_name("presentation_time_us");
                        builder.add_int_value(timing.get_presentation_time());
                        builder.end_object();
                        newest = index;
                    }
                }
                builder.end_array();
                traced_counters.set(clock, newest);
                for (int age = 1; age <= 8 && counter - age >= clock.get_history_start(); age++) {
                    var timing = clock.get_timings(counter - age);
                    if (timing != null && timing.get_complete() && timing.get_presentation_time() > 0) {
                        builder.set_member_name("presented_frame_counter");
                        builder.add_int_value(timing.get_frame_counter());
                        builder.set_member_name("presentation_time_us");
                        builder.add_int_value(timing.get_presentation_time());
                        break;
                    }
                }
            }
            write_trace(builder);
        }
    }
}

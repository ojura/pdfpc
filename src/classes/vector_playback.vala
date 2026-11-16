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
            cr.translate(area.x1, full_height - area.y2);
            // The fitted scene clips its paths. A second fractional region
            // clip here would prevent its background replacing poster pixels.
            scene.draw_fitted(cr, time, box_width, box_height, true);
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
        public bool waiting { get; private set; default = false; }
        public signal void started();
        private double target = 0;
        private double anchor_time = 0;
        private int64 anchor_clock = 0;
        private VectorTrace diagnostics;

        internal int64 playback_anchor_clock { get { return anchor_clock; } }
        internal double playback_anchor_time { get { return anchor_time; } }
        internal double playback_target { get { return target; } }
        public bool tracing_enabled { get { return diagnostics.enabled; } }

        public VectorPlayback(PresentationController controller) {
            this.controller = controller;
            diagnostics = new VectorTrace(this);
            string? speed_text = Environment.get_variable("PDFPC_VECTOR_SPEED");
            double requested_speed = 1;
            if (speed_text != null && double.try_parse(speed_text, out requested_speed) &&
                requested_speed >= 0.1 && requested_speed <= 8) {
                speed = requested_speed;
            }
            reload();
        }

        public void close_trace() { diagnostics.close(); }

        ~VectorPlayback() {
            close_trace();
        }

        public void reload() {
            playing = false;
            waiting = false;
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
            waiting = false;
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
            var view = primary_view();
            if (view != null && !view.vector_ready_for(page, binding)) {
                playing = false;
                waiting = true;
                changed("waiting-for-view");
                return;
            }
            waiting = false;
            anchor_time = time;
            anchor_clock = GLib.get_monotonic_time();
            playing = true;
            started();
            changed("play");
        }

        private View.Pdf? primary_view() {
            if (controller.presentation != null) return controller.presentation.main_view;
            if (controller.presenter != null) return controller.presenter.main_view;
            return null;
        }

        internal void view_ready(View.Pdf view) {
            if (waiting && view == primary_view() && view.vector_ready_for(page, binding)) {
                waiting = false;
                run_to(target);
            }
        }

        internal void view_unavailable(View.Pdf view) {
            if (view == primary_view()) pause();
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
            if (!playing && !waiting) {
                return;
            }
            advance(GLib.get_monotonic_time());
            playing = false;
            waiting = false;
            changed("pause");
        }

        public void seek(double position) {
            if (binding == null) {
                return;
            }
            playing = false;
            waiting = false;
            time = double.min(binding.scene.duration, double.max(0, position));
            target = time;
            changed("seek");
        }

        public bool next() {
            if (!can_play()) {
                return false;
            }
            if (playing || waiting) {
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
            if (playing || waiting) {
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
                scene.checkpoints[current].label,
                waiting ? "waiting for slide" : playing ? "playing" : "paused", speed);
        }

        public void trace_state(string reason, bool stdout_too = false) {
            diagnostics.trace_state(reason, stdout_too);
        }

        public int64 diagnostic_cpu_time() { return diagnostics.diagnostic_cpu_time(); }

        public void record_frame(string view, double displayed_time, int64 sample_clock_us, int64 render_us,
            int64 render_cpu_us, int width, int height, Gdk.FrameClock? clock,
            Cairo.SurfaceType target_type, Cairo.SurfaceType group_target_type) {
            diagnostics.record_frame(view, displayed_time, sample_clock_us, render_us,
                render_cpu_us, width, height, clock, target_type, group_target_type);
        }

        public void record_work(string name, string view, int work_page,
            int64 started_us, int64 wall_us, int64 cpu_us) {
            diagnostics.record_work(name, view, work_page, started_us, wall_us, cpu_us);
        }
    }
}

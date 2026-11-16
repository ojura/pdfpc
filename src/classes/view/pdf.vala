/**
 * Spezialized Pdf View
 *
 * This file is part of pdfpc.
 *
 * Copyright (C) 2010-2011 Jakob Westhoff <jakob@westhoffswelt.de>
 * Copyright 2011-2012 David Vilar
 * Copyright 2012, 2015, 2017 Andreas Bilke
 * Copyright 2012, 2015 Robert Schroll
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along
 * with this program; if not, write to the Free Software Foundation, Inc.,
 * 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
 */

namespace pdfpc {
    /**
     * View spezialized to work with Pdf renderers.
     *
     * This class is mainly needed to be decorated with pdf-link-interactions
     * signals.
     *
     * By default it does not implement any further functionality.
     */
    public class View.Pdf : Gtk.DrawingArea {
        /**
         * Signal fired every time a slide is about to be left
         */
        public signal void leaving_slide(int from, int to);

        /**
         * Signal fired every time a slide is fully entered (i.e, the
         * transition animation, if defined, is over)
         */
        public signal void entering_slide(int slide_number);

        /**
         * Flag that the entering_slide signal is queued
         */
        protected bool entering_slide_queued = false;

        /**
         * Renderer to be used for rendering the slides
         */
        protected Renderer.Pdf renderer;

        protected weak PresentationController controller;
        public bool vector_enabled = false;
        private uint vector_tick_id = 0;
        private bool vector_in_tick = false;
        private VectorBinding? vector_displayed_binding = null;
        private double vector_displayed_time = 0;
        private bool vector_ready = false;
        private bool destroyed = false;
        private ulong vector_changed_handler = 0;
        private TransitionManager? transition = null;
        private Cairo.ImageSurface? transition_next = null;
        private uint transition_steps_queued = 0;

        private bool audience_frozen() {
            return controller.presentation != null &&
                controller.presentation.main_view == this && controller.frozen;
        }

        internal bool vector_ready_for(int page, VectorBinding? binding) {
            return vector_ready && !destroyed && get_mapped() && !disabled &&
                current_slide_number == page && transition == null &&
                vector_displayed_binding == binding;
        }

        /** Copy the composed state currently held by this view. */
        internal Cairo.ImageSurface? snapshot() {
            if (buffer == null) return null;
            int width = buffer.get_width(), height = buffer.get_height();
            var result = new Cairo.ImageSurface(Cairo.Format.RGB24, width, height);
            var context = new Cairo.Context(result);
            context.set_source_surface(buffer, 0, 0);
            context.paint();
            if (transition == null && vector_enabled && !notes_area && !disabled &&
                vector_displayed_binding != null) {
                vector_displayed_binding.draw(context, get_metadata(),
                    vector_displayed_time, width, height, zoom_area);
            }
            return result;
        }

        private bool vector_can_tick() {
            var playback = controller.vector_animation;
            bool frozen = controller.presentation != null &&
                controller.presentation.main_view == this && controller.frozen;
            return !destroyed && vector_enabled && !notes_area && !disabled && !frozen &&
                transition == null && vector_ready &&
                get_mapped() && playback != null && playback.playing &&
                playback.page == current_slide_number;
        }

        private void vector_refresh() {
            if (!vector_enabled || destroyed) return;
            if (transition_next != null) {
                compose_into(transition_next, current_slide, current_slide_number);
            }
            this.queue_draw();
            if (vector_can_tick()) {
                if (vector_tick_id == 0) {
                    vector_tick_id = add_tick_callback((widget, clock) => {
                        vector_in_tick = true;
                        if (vector_can_tick()) {
                            // Controls and drawing use the same monotonic clock.
                            controller.vector_animation.advance(GLib.get_monotonic_time());
                            queue_draw();
                        }
                        bool keep = vector_can_tick();
                        vector_in_tick = false;
                        if (!keep) vector_tick_id = 0;
                        return keep;
                    });
                }
            } else if (vector_tick_id != 0 && !vector_in_tick) {
                remove_tick_callback(vector_tick_id);
                vector_tick_id = 0;
            }
        }

        private void draw_vector(Cairo.Context cr, int width, int height) {
            var playback = controller.vector_animation;
            if (!vector_enabled || notes_area || disabled || playback == null || transition != null) return;
            var binding = playback.binding_for(current_slide_number);
            if (binding == null) {
                vector_displayed_binding = null;
                vector_displayed_time = 0;
                return;
            }
            int64 sample_clock = GLib.get_monotonic_time();
            bool audience = controller.presentation != null && controller.presentation.main_view == this;
            if (vector_displayed_binding != binding) {
                vector_displayed_binding = binding;
                vector_displayed_time = playback.page == current_slide_number ? playback.time : 0;
            }
            if (!(audience && controller.frozen) && playback.page == current_slide_number) {
                // GDK schedules draws; elapsed monotonic time determines position.
                vector_displayed_time = playback.time_at(sample_clock);
            }
            int64 cpu_started = playback.diagnostic_cpu_time();
            int64 started = GLib.get_monotonic_time();
            binding.draw(cr, get_metadata(), vector_displayed_time, width, height, zoom_area);
            int64 render_us = GLib.get_monotonic_time() - started;
            int64 cpu_finished = playback.diagnostic_cpu_time();
            if (playback.tracing_enabled) {
                playback.record_frame(audience ? "presentation" : "presenter", vector_displayed_time,
                    sample_clock, render_us,
                    cpu_started < 0 || cpu_finished < 0 ? -1 : cpu_finished - cpu_started,
                    width, height, this.get_frame_clock(), cr.get_target().get_type(),
                    cr.get_group_target().get_type());
            }
        }

        private void compose_into(Cairo.ImageSurface destination, Cairo.ImageSurface pdf, int page) {
            var context = new Cairo.Context(destination);
            context.set_source_surface(pdf, 0, 0);
            context.paint();
            var playback = controller.vector_animation;
            if (!vector_enabled || notes_area || disabled || playback == null) return;
            var binding = playback.binding_for(page);
            if (binding == null) return;
            double position = playback.page == page ? playback.time : 0;
            binding.draw(context, get_metadata(), position,
                destination.get_width(), destination.get_height(), zoom_area);
        }

        private void stop_transition_timer() {
            if (transition_tid != 0) {
                Source.remove(transition_tid);
                transition_tid = 0;
            }
            transition_steps_queued = 0;
        }

        private void cancel_transition() {
            stop_transition_timer();
            transition = null;
            transition_next = null;
        }

        private void vector_freeze_changed(bool frozen) {
            if (frozen) {
                stop_transition_timer();
            } else if (current_slide != null && buffer != null &&
                (current_slide.get_width() != buffer.get_width() ||
                 current_slide.get_height() != buffer.get_height())) {
                display(controller.current_slide_number, true, zoom_area);
            }
            vector_refresh();
        }

        private void view_unmapped() {
            vector_ready = false;
            if (transition != null) {
                cancel_transition();
                buffer = current_slide;
                entering_slide_queued = true;
            }
            if (controller.vector_animation != null) {
                controller.vector_animation.view_unavailable(this);
            }
            vector_refresh();
        }

        private void view_destroyed() {
            destroyed = true;
            vector_ready = false;
            entering_slide_queued = false;
            cancel_prerender();
            cancel_transition();
            if (vector_tick_id != 0) {
                remove_tick_callback(vector_tick_id);
                vector_tick_id = 0;
            }
            if (controller.vector_animation != null) {
                controller.vector_animation.view_unavailable(this);
            }
            if (vector_changed_handler != 0) {
                controller.disconnect(vector_changed_handler);
                vector_changed_handler = 0;
            }
        }

        /**
         * Return the metadata object
         */
        public Metadata.Pdf get_metadata() {
            return this.renderer.metadata;
        }

        /**
         * Signal emitted on toggling the freeze state
         */
        public signal void freeze_toggled(bool frozen);

        /**
         * The currently displayed slide number
         */
        protected int current_slide_number;

        /**
         * and its rendered image
         */
        protected Cairo.ImageSurface current_slide;

        /**
         * Blit buffer
         */
        protected Cairo.ImageSurface buffer;

        /**
         * Whether the view should remain black
         */
        public bool disabled;

        /**
         * Whether the view will show only full user slides (without
         * intermediate overlays)
         */
        public bool user_slides;

        /**
         * The number of slides in the presentation
         */
        protected int n_slides {
            get {
                return (int) this.get_metadata().get_slide_count();
            }
        }

        /**
         * List to store all associated behaviours
         */
        protected GLib.List<View.Behaviour.Base> behaviours = new GLib.List<View.Behaviour.Base>();

        /**
         * GDK scale factor
         */
        protected int gdk_scale = 1;

        /**
         * Whether the PDF area to be displayed is (beamer) notes
         */
        protected bool notes_area;

        /**
         * ID of timeout used to delay pre-rendering
         */
        protected uint prerender_tid = 0;
        private int prerender_page = -1;
        private int prerender_last_page = -1;
        private bool prerender_deferred = false;

        /**
         * Transition timer
         */
        protected uint transition_tid = 0;

        public bool transitions_enabled = false;

        /**
         * Zoom area
         */
        protected PresentationController.ScaledRectangle? zoom_area = null;

        /**
         * Launch pre-rendering
         */
        protected virtual bool prerender() {
            this.prerender_tid = 0;

            // things might have changed during prerender_delay...
            if (this.disabled) {
                return GLib.Source.REMOVE;
            }

            var metadata = this.get_metadata();

            int first_page = this.current_slide_number + 1;
            first_page = metadata.nearest_nonhidden(first_page);
            if (first_page >= this.n_slides) {
                // nothing to pre-render
                return GLib.Source.REMOVE;
            }

            int last_slide;
            // negative number means prerender all
            if (Options.prerender_slides < 0) {
                last_slide = this.n_slides - 1;
            }
            else if (this.user_slides) {
                var user_slide = metadata.real_slide_to_user_slide(this.current_slide_number);
                var last_user_slide = user_slide + Options.prerender_slides;
                if (last_user_slide < metadata.get_user_slide_count()) {
                    last_slide =
                        metadata.user_slide_to_real_slide(last_user_slide, true);
                } else {
                    last_slide = this.n_slides - 1;
                }
            } else {
                last_slide = this.current_slide_number +
                    Options.prerender_slides;
                if (last_slide >= this.n_slides) {
                    last_slide = this.n_slides - 1;
                }
            }

            this.prerender_page = first_page;
            this.prerender_last_page = last_slide;
            this.prerender_deferred = false;
            this.prerender_tid = GLib.Idle.add(this.prerender_step);

            // don't repeat...
            return GLib.Source.REMOVE;
        }

        private void cancel_prerender() {
            if (this.prerender_tid != 0) {
                GLib.Source.remove(this.prerender_tid);
                this.prerender_tid = 0;
            }
            this.prerender_page = -1;
        }

        private bool prerender_step() {
            this.prerender_tid = 0;
            if (this.disabled || this.prerender_page < 0 ||
                this.prerender_page > this.prerender_last_page) return GLib.Source.REMOVE;

            var playback = controller.vector_animation;
            bool trace = playback != null && playback.tracing_enabled;
            bool audience = controller.presentation != null && controller.presentation.main_view == this;
            // Preview and notes views share the same GTK thread. Defer their
            // PDF rendering too, retaining the next page for the teaching pause.
            if (playback != null && playback.playing) {
                if (trace && !this.prerender_deferred) {
                    playback.record_work("pdf-prerender-deferred", audience ? "presentation" : "presenter",
                        this.prerender_page, GLib.get_monotonic_time(), 0, -1);
                }
                this.prerender_deferred = true;
                this.prerender_tid = GLib.Timeout.add(250, this.prerender_step);
                return GLib.Source.REMOVE;
            }

            var metadata = this.get_metadata();
            if (!this.user_slides || metadata.is_user_slide(this.prerender_page)) {
                int width, height;
                this.get_pixel_dimensions(out width, out height);
                int64 started = trace ? GLib.get_monotonic_time() : 0;
                int64 cpu_started = trace ? playback.diagnostic_cpu_time() : -1;
                try {
                    this.renderer.render(this.prerender_page, this.notes_area,
                        width, height, true);
                } catch(Renderer.RenderError e) {
                    GLib.printerr("Could pre-render page '%i': %s\n", this.prerender_page, e.message);
                }
                if (trace) {
                    int64 wall_us = GLib.get_monotonic_time() - started;
                    int64 cpu_finished = playback.diagnostic_cpu_time();
                    playback.record_work("pdf-prerender", audience ? "presentation" : "presenter",
                        this.prerender_page, started, wall_us,
                        cpu_started < 0 || cpu_finished < 0 ? -1 : cpu_finished - cpu_started);
                }
            }
            this.prerender_page = metadata.nearest_nonhidden(this.prerender_page + 1);
            if (this.prerender_page <= this.prerender_last_page) {
                this.prerender_tid = GLib.Idle.add(this.prerender_step);
            }
            return GLib.Source.REMOVE;
        }

        /**
         * Default constructor restricted to Pdf renderers as input parameter
         */
        protected Pdf(Renderer.Pdf renderer, bool notes_area,
            bool clickable_links, PresentationController controller,
            int gdk_scale_factor, bool user_slides) {
            this.renderer = renderer;
            this.controller = controller;
            vector_changed_handler = controller.vector_changed.connect(this.vector_refresh);
            this.map.connect(this.vector_refresh);
            this.unmap.connect(this.view_unmapped);
            this.destroy.connect(this.view_destroyed);
            this.freeze_toggled.connect(this.vector_freeze_changed);
            this.gdk_scale = gdk_scale_factor;
            this.notes_area = notes_area;
            this.user_slides = user_slides;

            this.current_slide_number = -1;

            this.add_events(Gdk.EventMask.STRUCTURE_MASK);

            if (clickable_links) {
                // Enable the PDFLink Behaviour by default on PDF Views
                this.associate_behaviour(new View.Behaviour.PdfLink());
            }
        }

        /**
         * Create a new Pdf view from a ControllableWindow instance
         *
         * This is a convenience constructor which automatically creates a full
         * metadata and rendering chain to be used with the pdf view.
         */
        public Pdf.from_controllable_window(Window.ControllableWindow window,
            bool notes_area, bool clickable_links, bool user_slides=false) {
            var controller = window.controller;
            var metadata = controller.metadata;

            var renderer = metadata.renderer;

            this(renderer, notes_area, clickable_links, controller, window.gdk_scale,
                user_slides);
        }

        /**
         * Convert an arbitrary Poppler.Rectangle struct into a Gdk.Rectangle
         * struct taking into account the measurement differences between pdf
         * space and screen space.
         */
        public Gdk.Rectangle convert_poppler_rectangle_to_gdk_rectangle(
            Poppler.Rectangle poppler_rectangle) {
            Gdk.Rectangle gdk_rectangle = Gdk.Rectangle();

            Gtk.Allocation allocation;
            this.get_allocation(out allocation);

            // We need the page dimensions for coordinate conversion between
            // pdf coordinates and screen coordinates
            var metadata = this.get_metadata();
            gdk_rectangle.x = (int) Math.ceil((poppler_rectangle.x1 / metadata.get_page_width()) *
                allocation.width );
            gdk_rectangle.width = (int) Math.floor(((poppler_rectangle.x2 - poppler_rectangle.x1) /
                metadata.get_page_width()) * allocation.width);

            // Gdk has its coordinate origin in the upper left, while Poppler
            // has its origin in the lower left.
            gdk_rectangle.y = (int) Math.ceil(((metadata.get_page_height() - poppler_rectangle.y2) /
                metadata.get_page_height()) * allocation.height);
            gdk_rectangle.height = (int) Math.floor(((poppler_rectangle.y2 - poppler_rectangle.y1) /
                metadata.get_page_height()) * allocation.height);

            return gdk_rectangle;
        }

        /**
         * Associate a new Behaviour with this View
         *
         * The implementation supports an arbitrary amount of different
         * behaviours.
         */
        public void associate_behaviour(Behaviour.Base behaviour) {
            this.behaviours.append(behaviour);
            try {
                behaviour.associate(this);
            } catch(Behaviour.AssociationError e) {
                GLib.printerr("Behaviour association failure: %s\n", e.message);
                Process.exit(1);
            }
        }

        /**
         * Display a specific slide number, optionally zooming in a
         * rectangular area
         */
        public void display(int slide_number, bool force = false,
            PresentationController.ScaledRectangle? rect = null) {
            if (destroyed || this.n_slides == 0) {
                return;
            }

            if (this.current_slide_number != slide_number || force) {
                int width, height;
                this.get_pixel_dimensions(out width, out height);
                // not ready yet
                if (height <= 1 || width <= 1) {
                    return;
                }

                var metadata = this.get_metadata();
                bool trans_inverse = false;
                bool sequential_move = false;
                if (slide_number ==
                    metadata.nearest_nonhidden(this.current_slide_number + 1)) {
                    sequential_move = true;
                } else if (slide_number ==
                    metadata.nearest_nonhidden(this.current_slide_number - 1,
                        true)) {
                    sequential_move = true;
                    trans_inverse = true;
                }
                int trans_slide_number;
                if (trans_inverse) {
                    trans_slide_number = this.current_slide_number;
                } else {
                    trans_slide_number = slide_number;
                }

                // The controller has already selected the next animation.
                // Keep the binding and time last painted by this view.
                var previous_slide = snapshot();
                vector_ready = false;
                entering_slide_queued = false;

                // Notify all listeners
                this.leaving_slide(this.current_slide_number, slide_number);

                this.current_slide_number = slide_number;

                this.zoom_area = rect;

                cancel_transition();

                try {
                    if (this.current_slide_number < this.n_slides &&
                        !this.disabled) {
                        this.current_slide =
                            this.renderer.render(this.current_slide_number,
                                this.notes_area, width, height,
                                false, false, this.zoom_area);

                        if (Options.prerender_slides != 0) {
                            // cancel any pending pre-rendering
                            this.cancel_prerender();

                            // wait before starting pre-rendering
                            this.prerender_tid =
                                GLib.Timeout.add(1000*Options.prerender_delay,
                                    this.prerender);
                        }
                    } else {
                        this.current_slide =
                            this.renderer.fade_to_black(width, height);
                    }
                } catch (Renderer.RenderError e) {
                    GLib.printerr("The pdf page %d could not be rendered: %s\n",
                        this.current_slide_number, e.message);
                    return;
                }

                if (!this.disabled && this.transitions_enabled &&
                    sequential_move && previous_slide != null &&
                    previous_slide.get_width() == width && previous_slide.get_height() == height) {
                    transition_next = new Cairo.ImageSurface(Cairo.Format.RGB24, width, height);
                    compose_into(transition_next, current_slide, current_slide_number);
                    transition = new View.TransitionManager(metadata,
                        trans_slide_number, previous_slide, transition_next,
                        trans_inverse);
                }

                if (transition == null || !transition.is_enabled) {
                    cancel_transition();
                    // Just the new slide
                    this.buffer = this.current_slide;

                    // Queue the signal
                    this.entering_slide_queued = true;

                    // Update the widget
                    this.queue_draw();
                } else {
                    this.buffer = new Cairo.ImageSurface(Cairo.Format.RGB24,
                        width, height);
                    transition.draw_frame(new Cairo.Context(this.buffer));
                    // Start stepping after GTK paints this complete first frame.
                    this.queue_draw();
                }
            }
        }

        /**
         * Invalidate the current slide, forcing redrawing on update
         */
        public void invalidate() {
            this.cancel_prerender();
            cancel_transition();
            vector_ready = false;
            entering_slide_queued = false;
            this.current_slide_number = -1;
            this.current_slide = null;
            this.buffer = null;
            this.vector_displayed_binding = null;
            if (controller.vector_animation != null) {
                controller.vector_animation.view_unavailable(this);
            }
            this.vector_refresh();
        }

        /**
         * Return pixel dimensions of the widget
         */
        protected void get_pixel_dimensions(out int width, out int height) {
            Gtk.Allocation allocation;
            this.get_allocation(out allocation);
            width = allocation.width*this.gdk_scale;
            height = allocation.height*this.gdk_scale;
        }

        /**
         * This method is called by Gdk every time the widget needs to be redrawn.
         *
         * The implementation does a simple blit from the internal pixmap to
         * the window surface.
         */
        protected override bool draw(Cairo.Context cr) {
            // not ready yet
            if (destroyed || this.buffer == null) {
                return true;
            }

            int width, height;
            this.get_pixel_dimensions(out width, out height);
            bool frozen = audience_frozen();
            // Re-render the slide on resize events
            if (width  != this.buffer.get_width() ||
                height != this.buffer.get_height()) {
                if (frozen) {
                    var held = new Cairo.ImageSurface(Cairo.Format.RGB24, width, height);
                    var held_cr = new Cairo.Context(held);
                    held_cr.scale((double) width/buffer.get_width(),
                        (double) height/buffer.get_height());
                    held_cr.set_source_surface(buffer, 0, 0);
                    held_cr.paint();
                    buffer = held;
                } else {
                cancel_transition();
                vector_ready = false;
                try {
                    this.current_slide =
                        this.disabled ? this.renderer.fade_to_black(width, height) :
                        this.renderer.render(this.current_slide_number,
                            this.notes_area, width, height,
                            false, false, this.zoom_area);
                } catch (Renderer.RenderError e) {
                    return true;
                }
                this.buffer = this.current_slide;
                this.entering_slide_queued = true;
                }
            }

            if (transition != null && !frozen) {
                while (transition_steps_queued > 0 && transition != null) {
                    transition_steps_queued--;
                    if (!transition.advance()) {
                        cancel_transition();
                        buffer = current_slide;
                        entering_slide_queued = true;
                    }
                }
                if (transition != null) {
                    transition.draw_frame(new Cairo.Context(buffer));
                }
            }

            cr.scale((1.0/this.gdk_scale), (1.0/this.gdk_scale));
            cr.set_source_surface(this.buffer, 0, 0);
            cr.paint();
            draw_vector(cr, width, height);

            if (transition != null && transition_tid == 0 && !frozen) {
                transition_tid = Timeout.add(transition.frame_duration, () => {
                    transition_steps_queued++;
                    queue_draw();
                    return Source.CONTINUE;
                }, Priority.HIGH);
            }

            int painted_page = current_slide_number;
            var painted_binding = vector_displayed_binding;
            bool became_ready = !vector_ready && transition == null && !frozen;
            if (transition == null && !frozen) vector_ready = true;

            if (this.entering_slide_queued && !frozen) {
                this.entering_slide_queued = false;
                // At this point, the transition to the new slide is over;
                // notify the listeners
                this.entering_slide(this.current_slide_number);
            }

            if (vector_ready && current_slide_number == painted_page &&
                vector_displayed_binding == painted_binding && controller.vector_animation != null) {
                controller.vector_animation.view_ready(this);
                if (became_ready) vector_refresh();
            }

            // We are the only ones drawing on this context; skip everything else
            return true;
        }
    }
}

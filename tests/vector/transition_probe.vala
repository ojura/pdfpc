// SPDX-License-Identifier: GPL-3.0-or-later
errordomain TransitionFailure { FAILED }

void require(bool condition, string message) throws TransitionFailure {
    if (!condition) throw new TransitionFailure.FAILED(message);
}

void pump(uint milliseconds) {
    int64 end = GLib.get_monotonic_time() + milliseconds*1000;
    do {
        while (MainContext.default().pending()) MainContext.default().iteration(false);
        Thread.usleep(1000);
    } while (GLib.get_monotonic_time() < end);
}

void capture(pdfpc.View.Pdf view, string prefix, string name) throws GLib.Error {
    var top = view.get_toplevel();
    int x, y;
    require(view.get_mapped() && top.get_window() != null,
        "The view must be mapped before capturing it");
    require(view.translate_coordinates(top, 0, 0, out x, out y),
        "The displayed view must have window coordinates");
    top.get_display().sync();
    var image = Gdk.pixbuf_get_from_window(top.get_window(), x, y,
        view.get_allocated_width(), view.get_allocated_height());
    require(image != null, "The painted view must be readable from its GDK window");
    image.save(prefix + "-" + name + ".png", "png");
}

void capture_region(pdfpc.View.Pdf view, string prefix, string phase) throws GLib.Error {
    capture(view, prefix, phase + "-window");
    var snapshot = view.snapshot();
    require(snapshot != null, "The displayed animation must have a composed snapshot");
    var poster = view.get_metadata().renderer.render(0, false,
        snapshot.get_width(), snapshot.get_height());
    require(snapshot.write_to_png(prefix + "-" + phase + "-snapshot.png") == Cairo.Status.SUCCESS &&
        poster.write_to_png(prefix + "-" + phase + "-poster.png") == Cairo.Status.SUCCESS,
        "Region comparison images must be writable");
}

// Observe the first real GTK frame after navigation rather than drawing the
// widget again or comparing two copies made by the production snapshot helper.
class FirstPaint : Object {
    private Gdk.FrameClock clock;
    private ulong handler;
    private bool captured = false;
    private string? failure = null;

    public FirstPaint(pdfpc.View.Pdf view, string prefix) {
        clock = view.get_frame_clock();
        handler = clock.after_paint.connect(() => {
            if (captured) return;
            captured = true;
            try {
                capture(view, prefix, "first");
            } catch (GLib.Error error) {
                failure = error.message;
            }
        });
    }

    public void wait() throws TransitionFailure {
        int64 deadline = GLib.get_monotonic_time() + 2000000;
        while (!captured && GLib.get_monotonic_time() < deadline) pump(1);
        close();
        require(captured, "Navigation must produce a GTK paint");
        require(failure == null, failure ?? "First-paint capture failed");
    }

    public void close() {
        if (handler != 0) {
            clock.disconnect(handler);
            handler = 0;
        }
    }

    ~FirstPaint() { close(); }
}

int main(string[] args) {
    Gtk.init(ref args);
    if (args.length != 4) return 2;
    new pdfpc.Options();
    pdfpc.Options.no_install = true;
    pdfpc.Options.prerender_slides = 0;
    pdfpc.Options.transition_fps = 40;
    var controller = new pdfpc.PresentationController();
    controller.metadata = new pdfpc.Metadata.Pdf(args[1]);
    pdfpc.Window.Presentation? audience = null;
    if (args[2] != "presenter-only") {
        audience = new pdfpc.Window.Presentation(controller, 0, true, 800, 600);
        controller.presentation = audience;
    }
    pdfpc.Window.Presenter? presenter = null;
    if (args[2] != "audience-only") {
        presenter = new pdfpc.Window.Presenter(controller, 0, true);
        controller.presenter = presenter;
        presenter.show_all();
    }
    if (audience != null) audience.show_all();
    pump(50);
    if (audience != null) audience.update();
    if (presenter != null) presenter.update();
    if (audience != null) audience.move(0, 0);
    if (presenter != null) {
        presenter.resize(700, 600);
        presenter.move(audience == null ? 0 : 850, 0);
    }
    pump(100);
    var view = audience != null ? audience.main_view : presenter.main_view;
    var animation = controller.vector_animation;
    for (int page = 0; page < controller.metadata.get_slide_count(); page++) {
        var trans = controller.metadata.document.get_page(page).get_transition();
        print("TRANS %d type=%d duration=%g fps=%u\n", page, (int) trans.type,
            trans.duration_real, pdfpc.Options.transition_fps);
    }
    view.leaving_slide.connect((from, to) => {
        print("LEAVE %d %d %" + int64.FORMAT + "\n", from, to, GLib.get_monotonic_time());
    });
    view.entering_slide.connect((page) => {
        print("ENTER %d %" + int64.FORMAT + "\n", page, GLib.get_monotonic_time());
    });
    view.size_allocate.connect((allocation) => {
        print("SIZE %d %d %" + int64.FORMAT + "\n", allocation.width, allocation.height,
            GLib.get_monotonic_time());
    });
    animation.started.connect(() => {
        print("START %d %" + int64.FORMAT + "\n", animation.page, GLib.get_monotonic_time());
    });
    try {
        if (args[2] == "region-edge") {
            animation.seek(0);
            pump(100);
            capture_region(view, args[3], "initial");
            audience.resize(642, 482);
            pump(150);
            capture_region(view, args[3], "resized");
        } else if (args[2] == "presenter-only") {
            require(controller.presentation == null, "This case must have no audience window");
            controller.switch_to_slide_number(1);
            pump(100);
            var first = new FirstPaint(view, args[3]);
            controller.switch_to_slide_number(2);
            controller.trigger_action("vectorPlayAll", null);
            require(animation.waiting && !animation.playing,
                "Presenter-only playback must wait for its newly selected page to be painted");
            first.wait();
            pump(100);
            require(animation.playing && animation.time > 0 && animation.time < 0.4,
                "The presenter's paint must release playback when there is no audience");
            capture(view, args[3], "final");
        } else if (args[2] == "outgoing") {
            animation.seek(1.5);
            pump(50);
            capture(view, args[3], "before");
            var first = new FirstPaint(view, args[3]);
            controller.switch_to_slide_number(1);
            first.wait();
            pump(300);
            capture(view, args[3], "middle");
            pump(650);
            capture(view, args[3], "final");
        } else {
            controller.switch_to_slide_number(1);
            pump(950);
            capture(view, args[3], "before");
            bool backwards = args[2] == "backward";
            var first = new FirstPaint(view, args[3]);
            controller.switch_to_slide_number(backwards ? 0 : 2);
            first.wait();
            if (args[2] == "incoming" || backwards) {
                pump(350);
                capture(view, args[3], "middle");
                pump(600);
                capture(view, args[3], "final");
                require(!animation.playing && animation.time == (backwards ? 3 : 0),
                    "Entering a page must retain the intended paused initial/final state");
            } else {
                string action = args[2] == "queued-toggle" ? "vectorToggle" :
                    args[2] == "queued-next" ? "next" : "vectorPlayAll";
                controller.trigger_action(action, null);
                pump(200);
                require(controller.current_slide_number == 2 && !animation.playing && animation.time == 0,
                    "Playback during entry: page=%d playing=%s waiting=%s time=%g".printf(
                        controller.current_slide_number, animation.playing.to_string(),
                        animation.waiting.to_string(), animation.time));
                if (args[2] == "cancel-page") {
                    controller.switch_to_slide_number(1);
                    pump(950);
                    require(controller.current_slide_number == 1 && !animation.playing,
                        "Leaving the pending page must cancel its queued playback");
                    capture(view, args[3], "cancelled");
                    controller.switch_to_slide_number(2);
                    controller.trigger_action("vectorPlayAll", null);
                    pump(950);
                    require(animation.playing && animation.time > 0 && animation.time < 0.4,
                        "Playback must recover after cancelling a previous page's start");
                } else if (args[2] == "cancel-blank" || args[2] == "blank-resize") {
                    controller.fade_to_black();
                    pump(950);
                    require(controller.faded_to_black && !animation.playing && animation.time == 0,
                        "Blanking must cancel pending playback without changing position");
                    capture(view, args[3], "blank");
                    if (args[2] == "blank-resize") {
                        audience.resize(640, 480);
                        pump(100);
                        capture(view, args[3], "resized");
                    }
                    controller.fade_to_black();
                    pump(100);
                    require(!animation.playing && !animation.waiting,
                        "Unblanking must not revive a cancelled start");
                    capture(view, args[3], "recovered");
                    controller.trigger_action("vectorPlayAll", null);
                    pump(150);
                    require(animation.playing && animation.time > 0,
                        "Playback must work after unblanking");
                } else if (args[2] == "cancel-toggle") {
                    controller.trigger_action("vectorToggle", null);
                    pump(950);
                    require(!animation.playing && animation.time == 0,
                        "Toggle must cancel a queued start");
                    controller.trigger_action("vectorToggle", null);
                    pump(150);
                    require(animation.playing && animation.time > 0,
                        "A later toggle must still start playback");
                } else if (args[2] == "cancel-seek" || args[2] == "cancel-finish") {
                    bool finish = args[2] == "cancel-finish";
                    controller.trigger_action(finish ? "vectorFinish" : "vectorNextCheckpoint", null);
                    pump(950);
                    require(!animation.playing && !animation.waiting &&
                        animation.time == (finish ? 3 : 1.5),
                        "Seeking or finishing must cancel the pending start and update the entry image");
                    capture(view, args[3], "final");
                } else if (args[2] == "cancel-reload") {
                    controller.trigger_action("reload", null);
                    pump(950);
                    animation = controller.vector_animation;
                    require(!animation.playing && !animation.waiting && animation.time == 0,
                        "Reload must discard the pending start and select the new binding");
                    capture(view, args[3], "recovered");
                    controller.trigger_action("vectorPlayAll", null);
                    pump(150);
                    require(animation.playing && animation.time > 0,
                        "The reloaded binding must be playable");
                } else if (args[2] == "rapid-navigation") {
                    controller.switch_to_slide_number(1);
                    controller.switch_to_slide_number(0);
                    controller.switch_to_slide_number(2);
                    pump(950);
                    require(!animation.playing && !animation.waiting && animation.time == 0,
                        "Rapid navigation must not release an old queued start");
                    capture(view, args[3], "recovered");
                    controller.trigger_action("vectorPlayAll", null);
                    pump(150);
                    require(animation.playing && animation.time > 0,
                        "Playback must work on the final page after rapid navigation");
                } else if (args[2] == "freeze") {
                    controller.toggle_freeze();
                    require(controller.frozen, "The audience must enter the frozen state");
                    pump(50);
                    capture(view, args[3], "held");
                    pump(950);
                    capture(view, args[3], "held-later");
                    require(!animation.playing && !animation.waiting && animation.time == 0,
                        "Freezing during entry must cancel the queued animation");
                    audience.resize(640, 480);
                    pump(100);
                    capture(view, args[3], "resized");
                    controller.toggle_freeze();
                    pump(950);
                    require(!animation.playing && !animation.waiting,
                        "Unfreezing must not revive the cancelled request");
                    controller.trigger_action("vectorPlayAll", null);
                    pump(150);
                    require(animation.playing && animation.time > 0,
                        "Playback must recover after unfreezing the resized audience");
                } else if (args[2] == "destroy-waiting" || args[2] == "destroy-playing") {
                    if (args[2] == "destroy-playing") {
                        pump(750);
                        require(animation.playing, "This case must destroy a playing view");
                    }
                    view.destroy();
                    controller.presentation = null;
                    double stopped = animation.time;
                    pump(950);
                    require(!animation.playing && !animation.waiting && animation.time == stopped,
                        "Destroying the primary view must cancel its tick and pending start");
                    controller.trigger_action("vectorPlayAll", null);
                    pump(150);
                    require(animation.playing && animation.time > stopped,
                        "The remaining presenter must be able to take over playback");
                    capture(presenter.main_view, args[3], "recovered");
                } else if (args[2] == "resize") {
                    audience.resize(640, 480);
                    pump(350);
                    require(animation.playing && animation.time > 0 && animation.time < 0.4,
                        "Resizing must finish the composed entry before starting its queued playback");
                    capture(view, args[3], "resized");
                } else {
                    pump(750);
                    require(animation.playing && animation.time > 0 && animation.time < 0.5,
                        "Queued playback must start only after the audience's transition finishes");
                }
            }
        }
        print("PASS %s\n", args[2]);
        animation.close_trace();
        return 0;
    } catch (GLib.Error error) {
        printerr("FAIL %s: %s\n", args[2], error.message);
        animation.close_trace();
        return 1;
    }
}

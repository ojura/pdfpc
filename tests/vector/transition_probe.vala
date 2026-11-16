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

void capture(pdfpc.View.Pdf view, string prefix, string name) throws TransitionFailure {
    var image = view.snapshot();
    require(image != null, "A displayed page must have a composed surface");
    require(image.write_to_png(prefix + "-" + name + ".png") == Cairo.Status.SUCCESS,
        "The actual view snapshot must be writable");
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
    var audience = new pdfpc.Window.Presentation(controller, 0, true, 800, 600);
    controller.presentation = audience;
    pdfpc.Window.Presenter? presenter = null;
    if (args[2] != "audience-only") {
        presenter = new pdfpc.Window.Presenter(controller, 0, true);
        controller.presenter = presenter;
        presenter.show_all();
    }
    audience.show_all();
    pump(50);
    audience.update();
    if (presenter != null) presenter.update();
    pump(100);
    var animation = controller.vector_animation;
    for (int page = 0; page < controller.metadata.get_slide_count(); page++) {
        var trans = controller.metadata.document.get_page(page).get_transition();
        print("TRANS %d type=%d duration=%g fps=%u\n", page, (int) trans.type,
            trans.duration_real, pdfpc.Options.transition_fps);
    }
    audience.main_view.leaving_slide.connect((from, to) => {
        print("LEAVE %d %d %" + int64.FORMAT + "\n", from, to, GLib.get_monotonic_time());
    });
    audience.main_view.entering_slide.connect((page) => {
        print("ENTER %d %" + int64.FORMAT + "\n", page, GLib.get_monotonic_time());
    });
    audience.main_view.size_allocate.connect((allocation) => {
        print("SIZE %d %d %" + int64.FORMAT + "\n", allocation.width, allocation.height,
            GLib.get_monotonic_time());
    });
    animation.started.connect(() => {
        print("START %d %" + int64.FORMAT + "\n", animation.page, GLib.get_monotonic_time());
    });
    try {
        if (args[2] == "outgoing") {
            animation.seek(1.5);
            pump(50);
            capture(audience.main_view, args[3], "before");
            controller.switch_to_slide_number(1);
            capture(audience.main_view, args[3], "first");
            pump(300);
            capture(audience.main_view, args[3], "middle");
            pump(650);
            capture(audience.main_view, args[3], "final");
        } else {
            controller.switch_to_slide_number(1);
            pump(950);
            capture(audience.main_view, args[3], "before");
            bool backwards = args[2] == "backward";
            controller.switch_to_slide_number(backwards ? 0 : 2);
            capture(audience.main_view, args[3], "first");
            if (args[2] == "incoming" || backwards) {
                pump(350);
                capture(audience.main_view, args[3], "middle");
                pump(600);
                capture(audience.main_view, args[3], "final");
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
                } else if (args[2] == "cancel-blank") {
                    controller.fade_to_black();
                    pump(950);
                    require(controller.faded_to_black && !animation.playing && animation.time == 0,
                        "Blanking must cancel pending playback without changing position");
                } else if (args[2] == "cancel-toggle") {
                    controller.trigger_action("vectorToggle", null);
                    pump(950);
                    require(!animation.playing && animation.time == 0,
                        "Toggle must cancel a queued start");
                } else if (args[2] == "resize") {
                    audience.resize(640, 480);
                    pump(350);
                    require(animation.playing && animation.time > 0 && animation.time < 0.4,
                        "Resizing must finish the composed entry before starting its queued playback");
                    capture(audience.main_view, args[3], "resized");
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

// SPDX-License-Identifier: GPL-3.0-or-later
// The real controller, timer, metadata and vector playback run in this process.
errordomain CheckFailure { FAILED }

void check(bool condition, string message) throws CheckFailure {
    if (!condition) throw new CheckFailure.FAILED(message);
}

void pump(uint milliseconds) {
    var until = GLib.get_monotonic_time() + milliseconds*1000;
    do {
        while (MainContext.default().pending()) MainContext.default().iteration(false);
        Thread.usleep(1000);
    } while (GLib.get_monotonic_time() < until);
}

int main(string[] args) {
    Gtk.init(ref args);
    if (args.length != 3) return 2;
    new pdfpc.Options();
    pdfpc.Options.no_install = true;
    pdfpc.Options.prerender_slides = 0;
    var controller = new pdfpc.PresentationController();
    controller.metadata = new pdfpc.Metadata.Pdf(args[1]);
    var animation = controller.vector_animation;
    try {
        check(animation.binding != null, "The actual PDF must bind its first animated page");
        check(!controller.is_running() && !controller.is_paused(), "Initial timer must be stopped");
        switch (args[2]) {
        case "next-start":
            controller.next_page();
            check(animation.playing && controller.current_slide_number == 0,
                "Next must start the first animation, not leave its PDF page");
            check(controller.is_running(), "Animation Next must start the talk timer");
            break;
        case "next-resume":
            controller.trigger_action("start", null);
            controller.toggle_pause();
            check(controller.is_paused(), "Setup must pause the talk timer");
            controller.next_page();
            check(animation.playing && controller.is_running(),
                "Animation Next must resume the paused talk timer");
            break;
        case "toggle-start":
        case "all-start":
            controller.trigger_action(args[2] == "toggle-start" ? "vectorToggle" : "vectorPlayAll", null);
            check(animation.playing && controller.is_running(),
                "Direct animation playback must start the talk timer");
            controller.trigger_action("vectorToggle", null);
            check(!animation.playing && controller.is_running(),
                "Pausing animation must leave the talk timer running");
            break;
        case "initial-autoadvance":
            controller.next_page();
            pump(1100);
            check(controller.current_slide_number == 1,
                "Starting the initial animation must arm its page-duration timer");
            break;
        case "resumed-autoadvance":
            controller.trigger_action("start", null);
            controller.toggle_pause();
            pump(1000);
            check(controller.current_slide_number == 0, "Paused talk must not auto-advance");
            controller.next_page();
            pump(1100);
            check(controller.current_slide_number == 1,
                "Animation Next must rearm page duration when the talk resumes");
            break;
        case "checkpoint-keeps-deadline":
            controller.next_page();
            pump(400);
            controller.trigger_action("vectorNextCheckpoint", null);
            controller.next_page();
            pump(700);
            check(controller.current_slide_number == 1,
                "Starting another segment must not reset the current page-duration timer");
            break;
        case "no-duration":
            controller.next_page();
            check(controller.is_running() && animation.playing,
                "Animation starts the talk even without a page duration");
            pump(1100);
            check(controller.current_slide_number == 0,
                "A page without a duration must not advance automatically");
            controller.toggle_pause();
            animation.pause();
            controller.trigger_action("vectorPlayAll", null);
            check(controller.is_running() && animation.playing,
                "Direct playback resumes the talk without a page duration");
            break;
        case "blocked-stopped":
        case "blocked-paused":
            if (args[2] == "blocked-paused") {
                controller.trigger_action("start", null);
                controller.toggle_pause();
            }
            controller.fade_to_black();
            check(controller.faded_to_black, "Setup must blank the audience");
            for (int endpoint = 0; endpoint < 2; endpoint++) {
                if (endpoint == 1) controller.trigger_action("vectorFinish", null);
                double held = animation.time;
                foreach (var action in new string[] {"vectorToggle", "vectorPlayAll"}) {
                    controller.trigger_action(action, null);
                    pump(50);
                    check(!animation.playing && animation.time == held &&
                        controller.current_slide_number == 0 && !controller.is_running() &&
                        controller.is_paused() == (args[2] == "blocked-paused"),
                        "Blanked direct playback must preserve animation and talk-timer state");
                }
            }
            break;
        case "hang":
            print("READY hang\n");
            stdout.flush();
            while (true) pump(100);
        default:
            throw new CheckFailure.FAILED("Unknown controller case");
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

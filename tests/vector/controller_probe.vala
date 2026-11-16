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

class ProbePresenter : pdfpc.Window.Presenter {
    public ProbePresenter(pdfpc.PresentationController controller) {
        base(controller, 0, true);
    }

    public bool pause_indicator_visible {
        get { return pause_icon != null && pause_icon.get_visible(); }
    }

    public bool pause_indicator_mapped {
        get { return pause_icon != null && pause_icon.get_mapped(); }
    }

    public void report_vector_buttons(Json.Builder report) throws CheckFailure {
        report.set_member_name("buttons");
        report.begin_array();
        int count = 0;
        foreach (var child in vector_controls.get_children()) {
            var button = child as Gtk.Button;
            if (button == null) continue;
            count++;
            report.begin_object();
            report.set_member_name("tooltip");
            if (button.tooltip_text == null) report.add_null_value();
            else report.add_string_value(button.tooltip_text);
            report.set_member_name("has_tooltip");
            report.add_boolean_value(button.has_tooltip);
            report.set_member_name("mapped");
            report.add_boolean_value(button.get_mapped());
            report.end_object();
        }
        report.end_array();
        check(count == 4, "Inspect all four actual vector controls");
        report.set_member_name("status_tooltip");
        if (vector_status.tooltip_text == null) report.add_null_value();
        else report.add_string_value(vector_status.tooltip_text);
    }

    public void check_vector_button_actions() throws CheckFailure {
        Gtk.Button[] buttons = {};
        foreach (var child in vector_controls.get_children()) {
            if (child is Gtk.Button) buttons += (Gtk.Button) child;
        }
        var animation = controller.vector_animation;
        animation.seek(animation.binding.scene.duration);
        buttons[0].clicked();
        check(animation.time == 0, "The actual restart button must return to the initial state");
        buttons[3].clicked();
        check(animation.time > 0 && !animation.playing,
            "The actual next-checkpoint button must seek without playing");
        buttons[1].clicked();
        check(animation.time == 0, "The actual previous-checkpoint button must seek backward");
        buttons[2].clicked();
        var deadline = GLib.get_monotonic_time() + 2000000;
        while (animation.waiting && GLib.get_monotonic_time() < deadline) pump(5);
        check(animation.playing, "The actual toggle button must start playback");
        buttons[2].clicked();
        check(!animation.playing, "The actual toggle button must pause playback");
    }
}

int main(string[] args) {
    Gtk.init(ref args);
    if (args.length < 3) return 2;
    new pdfpc.Options();
    pdfpc.Options.no_install = true;
    pdfpc.Options.prerender_slides = 0;
    if (args[2] == "bindings") {
        var config = new pdfpc.ConfigFileReader();
        config.readConfig(pdfpc.Resources.resolve_system_config());
        for (int i = 3; i < args.length; i++) config.parseStatement(args[i]);
    }
    var controller = new pdfpc.PresentationController();
    controller.metadata = new pdfpc.Metadata.Pdf(args[1]);
    var animation = controller.vector_animation;
    try {
        check(animation.binding != null, "The actual PDF must bind its first animated page");
        check(!controller.is_running() && !controller.is_paused(), "Initial timer must be stopped");
        switch (args[2]) {
        case "bindings":
            var presenter = new ProbePresenter(controller);
            controller.presenter = presenter;
            presenter.show_all();
            pump(200);
            presenter.update();
            var report = new Json.Builder();
            report.begin_object();
            report.set_member_name("bindings");
            report.begin_array();
            foreach (var value in controller.get_action_bindings()) report.add_string_value(value);
            report.end_array();
            report.set_member_name("descriptions");
            report.begin_array();
            foreach (var value in controller.get_action_descriptions()) report.add_string_value(value);
            report.end_array();
            presenter.report_vector_buttons(report);
            report.end_object();
            var generator = new Json.Generator();
            generator.set_root(report.get_root());
            print("BINDINGS %s\n", generator.to_data(null));
            presenter.check_vector_button_actions();
            presenter.hide();
            break;
        case "trace-release":
            animation.close_trace();
            var presenter = new ProbePresenter(controller);
            controller.presenter = presenter;
            presenter.show_all();
            pump(200);
            var clock = presenter.main_view.get_frame_clock();
            check(clock != null && clock.get_frame_counter() >= 0,
                "The lifetime case needs an actual GTK frame clock");
            pdfpc.VectorPlayback? temporary = new pdfpc.VectorPlayback(controller);
            var released = GLib.WeakRef(temporary);
            temporary.record_frame("lifetime", 0, GLib.get_monotonic_time(), 0, -1,
                800, 600, clock, Cairo.SurfaceType.IMAGE, Cairo.SurfaceType.IMAGE);
            check(temporary.tracing_enabled, "The stopped collector must have an enabled sink");
            // Drop the only strong playback reference before iterating the
            // loop: a diagnostic timeout must not postpone its destruction.
            temporary = null;
            check(released.get() == null, "The collector retained its playback owner");
            string before, after;
            string? filename = Environment.get_variable("PDFPC_VECTOR_TRACE");
            check(filename != null, "The lifetime case needs a trace file");
            FileUtils.get_contents(filename, out before);
            pump(550);
            FileUtils.get_contents(filename, out after);
            check(before == after, "A stopped collector wrote after playback destruction");
            presenter.hide();
            break;
        case "trace-failure":
        case "trace-normal":
        case "trace-none":
            bool initial_trace = animation.tracing_enabled;
            var presenter = new ProbePresenter(controller);
            controller.presenter = presenter;
            presenter.show_all();
            pump(200);
            presenter.update();
            controller.trigger_action("vectorPlayAll", null);
            var ready_by = GLib.get_monotonic_time() + 2000000;
            while (animation.waiting && GLib.get_monotonic_time() < ready_by) pump(5);
            check(animation.playing && controller.is_running(),
                "A trace sink must not prevent animation or the talk timer starting");
            pump(80);
            animation.pause();
            double advanced_time = animation.time;
            check(advanced_time > 0, "Playback must continue after a trace write error");
            controller.trigger_action("vectorStatus", null);
            for (int i = 0; i < 3; i++) {
                animation.seek(0.1*(i + 1));
            }
            pump(550);
            bool after_play = animation.tracing_enabled;
            int64 diagnostic_cpu = animation.diagnostic_cpu_time();
            animation.close_trace();
            animation.close_trace();
            controller.trigger_action("vectorStatus", null);
            pump(50);
            var report = new Json.Builder();
            report.begin_object();
            report.set_member_name("initial_enabled");
            report.add_boolean_value(initial_trace);
            report.set_member_name("after_play_enabled");
            report.add_boolean_value(after_play);
            report.set_member_name("after_close_enabled");
            report.add_boolean_value(animation.tracing_enabled);
            report.set_member_name("advanced_time");
            report.add_double_value(advanced_time);
            report.set_member_name("diagnostic_cpu_us");
            report.add_int_value(diagnostic_cpu);
            report.end_object();
            var generator = new Json.Generator();
            generator.set_root(report.get_root());
            print("TRACE %s\n", generator.to_data(null));
            presenter.hide();
            bool expected_trace = args[2] == "trace-normal";
            check(initial_trace == expected_trace,
                "Early reload must disable a trace sink that rejects its first write");
            check(after_play == expected_trace,
                "A failed trace sink must stay disabled while lecture controls continue");
            check(expected_trace || diagnostic_cpu == -1,
                "Disabled trace collection must not sample diagnostic CPU time");
            check(!animation.tracing_enabled, "Closing a trace is idempotent");
            break;
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
        case "presenter-resume":
            var presenter = new ProbePresenter(controller);
            controller.presenter = presenter;
            presenter.show_all();
            pump(200);
            presenter.update();
            controller.trigger_action("start", null);
            foreach (var action in new string[] {"next", "vectorToggle", "vectorPlayAll"}) {
                animation.seek(0);
                controller.toggle_pause();
                pump(50);
                check(controller.is_paused() && presenter.pause_indicator_mapped,
                    "The actual presenter must display the paused talk indicator");
                controller.fade_to_black();
                controller.trigger_action("vectorToggle", null);
                controller.trigger_action("vectorPlayAll", null);
                pump(50);
                check(controller.is_paused() && presenter.pause_indicator_visible,
                    "Blocked direct playback must retain the visible paused indicator");
                controller.fade_to_black();
                controller.trigger_action(action, null);
                pump(50);
                check(controller.is_running() && !presenter.pause_indicator_visible,
                    "Successful animation resume must clear the presenter's pause indicator");
            }
            presenter.hide();
            break;
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

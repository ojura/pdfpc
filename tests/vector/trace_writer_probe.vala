// SPDX-License-Identifier: GPL-3.0-or-later
// Exercise the production JSON writer directly, without GTK or a second serializer.

void emit_event(pdfpc.VectorTraceWriter writer) {
    writer.finish();
    stdout.printf("%s\n", writer.data);
}

int main(string[] args) {
    string requested_locale = args.length > 1 ? args[1] : "C";
    if (Intl.setlocale(LocaleCategory.ALL, requested_locale) == null) {
        stderr.printf("Locale unavailable: %s\n", requested_locale);
        return 77;
    }
    stderr.printf("numeric-sample:%s\n", "%.1f".printf(1.5));
    if (args.length > 2 && args[2] == "--locale-only") return 0;

    var writer = new pdfpc.VectorTraceWriter();
    var controls = new StringBuilder();
    // Vala strings are NUL-terminated; these are every representable C0 byte.
    for (int byte = 1; byte < 32; byte++) controls.append_c((char) byte);
    writer.begin_event("quote \" slash \\ newline\n ž中🙂", int64.MAX);
    writer.add_string("controls", controls.str);
    writer.add_string("key\"\\\nž", "value\"\\\t\r\n");
    writer.add_string("unicode", "ž中🙂\u2028\u2029");
    writer.add_string("empty", "");
    writer.add_string("missing", null);
    writer.add_string("literal_null", "null");
    writer.add_bool("yes", true);
    writer.add_bool("no", false);
    emit_event(writer);

    writer.begin_event("numbers", 0);
    writer.add_int("minimum_int", int64.MIN);
    writer.add_int("maximum_int", int64.MAX);
    writer.add_int("beyond_double_integer", 9007199254740993);
    writer.add_double("decimal", 1.5);
    writer.add_double("fraction", 0.1);
    writer.add_double("maximum_double", 1.7976931348623157e308);
    writer.add_double("minimum_normal", 2.2250738585072014e-308);
    writer.add_double("minimum_subnormal", 4.9406564584124654e-324);
    writer.add_double("negative_maximum", -1.7976931348623157e308);
    writer.add_double("positive_zero", 0.0);
    writer.add_double("negative_zero", -0.0);
    writer.add_double("not_a_number", double.NAN);
    writer.add_double("positive_infinity", double.INFINITY);
    writer.add_double("negative_infinity", -double.INFINITY);
    emit_event(writer);

    writer.begin_event("timing", 1234567890123456);
    writer.add_int("frame_clock_id", 2);
    writer.begin_timings();
    writer.add_timing(9007199254740993, int64.MAX, false);
    writer.add_timing(8, 0, false);
    writer.add_timing(9, 0, true);
    writer.end_timings();
    writer.add_int("feedback_collected_us", int64.MAX);
    emit_event(writer);

    var long_text = new StringBuilder();
    for (int i = 0; i < 8192; i++) long_text.append("ž中🙂\"\\\n");
    writer.begin_event("long", 3);
    writer.add_string("text", long_text.str);
    emit_event(writer);

    writer.begin_event("empty-array", 4);
    writer.begin_timings();
    writer.end_timings();
    emit_event(writer);
    for (int i = 0; i < 128; i++) {
        writer.begin_event("reused", i);
        writer.add_int("index", i);
        writer.add_string("text", i % 2 == 0 ? "" : "short");
        writer.begin_timings();
        if (i % 2 != 0) writer.add_timing(i, i*1000, false);
        writer.end_timings();
        emit_event(writer);
    }
    return 0;
}

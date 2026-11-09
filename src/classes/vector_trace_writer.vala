// SPDX-License-Identifier: GPL-3.0-or-later
// Reuse one text buffer instead of allocating a JSON object graph per frame.

namespace pdfpc {
    internal class VectorTraceWriter : Object {
        private StringBuilder buffer = new StringBuilder.sized(2048);
        private bool first_timing = true;

        public unowned string data { get { return buffer.str; } }

        private void quoted(string value) {
            buffer.append_c('"');
            int length = value.length;
            for (int i = 0; i < length; i++) {
                char byte = value[i];
                switch (byte) {
                case '"': buffer.append("\\\""); break;
                case '\\': buffer.append("\\\\"); break;
                case '\b': buffer.append("\\b"); break;
                case '\f': buffer.append("\\f"); break;
                case '\n': buffer.append("\\n"); break;
                case '\r': buffer.append("\\r"); break;
                case '\t': buffer.append("\\t"); break;
                default:
                    if ((uchar) byte < 0x20) {
                        buffer.append_printf("\\u%04x", (uint) (uchar) byte);
                    } else {
                        // Preserve the original UTF-8 bytes.
                        buffer.append_c(byte);
                    }
                    break;
                }
            }
            buffer.append_c('"');
        }

        private void member(string name) {
            buffer.append_c(',');
            quoted(name);
            buffer.append_c(':');
        }

        private void integer(int64 value) {
            buffer.append_printf("%" + int64.FORMAT, value);
        }

        public void begin_event(string kind, int64 clock_us) {
            buffer.truncate(0);
            buffer.append("{\"event\":");
            quoted(kind);
            add_int("clock_us", clock_us);
        }

        public void add_string(string name, string? value) {
            member(name);
            if (value == null) buffer.append("null");
            else quoted(value);
        }

        public void add_int(string name, int64 value) {
            member(name);
            integer(value);
        }

        public void add_double(string name, double value) {
            member(name);
            if (!(value >= -double.MAX && value <= double.MAX)) {
                // Keep diagnostic output valid even if an invalid value reaches it.
                buffer.append("null");
                return;
            }
            // Vala's conversion uses g_ascii_dtostr, independent of LC_NUMERIC.
            string number = value.to_string();
            buffer.append(number);
            if (!number.contains(".") && !number.contains("e") && !number.contains("E")) {
                buffer.append(".0");
            }
        }

        public void add_bool(string name, bool value) {
            member(name);
            buffer.append(value ? "true" : "false");
        }

        public void begin_timings() {
            member("completed_timings");
            buffer.append_c('[');
            first_timing = true;
        }

        public void add_timing(int64 counter, int64 presentation_time_us, bool expired) {
            if (!first_timing) buffer.append_c(',');
            first_timing = false;
            buffer.append("{\"counter\":");
            integer(counter);
            buffer.append(",\"presentation_time_us\":");
            integer(presentation_time_us);
            buffer.append(",\"expired\":");
            buffer.append(expired ? "true" : "false");
            buffer.append_c('}');
        }

        public void end_timings() {
            buffer.append_c(']');
        }

        public void finish() {
            buffer.append_c('}');
        }
    }
}

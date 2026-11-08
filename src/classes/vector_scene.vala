// SPDX-License-Identifier: GPL-3.0-or-later
// Manim paths remain vectors until Cairo draws them at the output resolution.

namespace pdfpc {
    public errordomain VectorError {
        INVALID
    }

    public class VectorJson : Object {
        public static Json.Node member(Json.Object obj, string name) throws VectorError {
            if (!obj.has_member(name)) {
                throw new VectorError.INVALID("Missing member '%s'", name);
            }
            return obj.get_member(name);
        }

        public static Json.Object object_node(Json.Node node) throws VectorError {
            if (node.get_node_type() != Json.NodeType.OBJECT) {
                throw new VectorError.INVALID("Expected a JSON object");
            }
            return node.get_object();
        }

        public static Json.Array array_node(Json.Node node) throws VectorError {
            if (node.get_node_type() != Json.NodeType.ARRAY) {
                throw new VectorError.INVALID("Expected a JSON array");
            }
            return node.get_array();
        }

        public static string string_node(Json.Node node) throws VectorError {
            if (node.get_node_type() != Json.NodeType.VALUE ||
                node.get_value_type() != typeof(string)) {
                throw new VectorError.INVALID("Expected a JSON string");
            }
            return node.get_string();
        }

        public static double number(Json.Node node) throws VectorError {
            if (node.get_node_type() != Json.NodeType.VALUE) {
                throw new VectorError.INVALID("Expected a JSON number");
            }
            var kind = node.get_value_type();
            if (kind != typeof(double) && kind != typeof(int64)) {
                throw new VectorError.INVALID("Expected a JSON number");
            }
            double value = node.get_double();
            if (value != value || value < -1e9 || value > 1e9) {
                throw new VectorError.INVALID("Number must be finite and within +/- 1e9");
            }
            return value;
        }

        public static double[] numbers(Json.Node node, int expected = -1,
            bool color = false) throws VectorError {
            var array = array_node(node);
            int size = (int) array.get_length();
            if ((expected >= 0 && size != expected) || size > 200000) {
                throw new VectorError.INVALID("Unexpected vector length %d (expected %d)",
                    size, expected);
            }
            double[] values = new double[size];
            for (int i = 0; i < size; i++) {
                values[i] = number(array.get_element(i));
                if (color && (values[i] < 0 || values[i] > 1)) {
                    throw new VectorError.INVALID("RGBA values must be between 0 and 1");
                }
            }
            return values;
        }
    }

    public class VectorCoordinates : Object {
        public double[] values;

        public VectorCoordinates(Json.Node node, int count) throws VectorError {
            values = VectorJson.numbers(node, count);
        }
    }

    public class VectorKeyframe : Object {
        public double time;
        public VectorCoordinates geometry;
        public double[] fill;
        public double[] stroke;
        public double stroke_width;

        public VectorKeyframe(Json.Object obj, int coordinate_count,
            VectorCoordinates? previous_geometry = null) throws VectorError {
            time = VectorJson.number(VectorJson.member(obj, "time"));
            if (obj.has_member("coords")) {
                geometry = new VectorCoordinates(obj.get_member("coords"), coordinate_count);
            } else if (previous_geometry != null) {
                geometry = previous_geometry;
            } else {
                throw new VectorError.INVALID("The first keyframe must supply path coordinates");
            }
            fill = VectorJson.numbers(VectorJson.member(obj, "fill"), 4, true);
            stroke = VectorJson.numbers(VectorJson.member(obj, "stroke"), 4, true);
            stroke_width = VectorJson.number(VectorJson.member(obj, "stroke_width"));
            if (time < 0 || stroke_width < 0) {
                throw new VectorError.INVALID("Negative time or stroke width");
            }
        }
    }

    public class VectorObject : Object {
        public string id;
        public double z;
        public string commands;
        public VectorKeyframe[] keyframes;
        public Cairo.FillRule fill_rule = Cairo.FillRule.WINDING;
        private Cairo.Path? fixed_path = null;
        private double[] interpolated;

        public VectorObject(Json.Object obj, double duration) throws VectorError {
            id = VectorJson.string_node(VectorJson.member(obj, "id"));
            z = obj.has_member("z") ? VectorJson.number(obj.get_member("z")) : 0;
            commands = VectorJson.string_node(VectorJson.member(obj, "commands"));
            if (id == "" || commands.length == 0 || commands[0] != 'M') {
                throw new VectorError.INVALID("Vector object needs an ID and a path beginning with M");
            }
            int coordinate_count = 0;
            for (int i = 0; i < commands.length; i++) {
                switch (commands[i]) {
                case 'M': case 'L': coordinate_count += 2; break;
                case 'C': coordinate_count += 6; break;
                case 'Q': coordinate_count += 4; break;
                case 'Z': break;
                default:
                    throw new VectorError.INVALID("Object '%s': unsupported path command", id);
                }
            }
            if (coordinate_count > 200000) {
                throw new VectorError.INVALID("Object '%s' has too many coordinates", id);
            }
            if (obj.has_member("fill_rule")) {
                string rule = VectorJson.string_node(obj.get_member("fill_rule"));
                if (rule == "evenodd") {
                    fill_rule = Cairo.FillRule.EVEN_ODD;
                } else if (rule != "nonzero") {
                    throw new VectorError.INVALID("Object '%s': unsupported fill rule", id);
                }
            }
            var states = VectorJson.array_node(VectorJson.member(obj, "keyframes"));
            int count = (int) states.get_length();
            if (count < 1 || count > 200000) {
                throw new VectorError.INVALID("Object '%s': invalid keyframe count", id);
            }
            keyframes = new VectorKeyframe[count];
            bool fixed_geometry = true;
            for (int i = 0; i < count; i++) {
                keyframes[i] = new VectorKeyframe(VectorJson.object_node(states.get_element(i)),
                    coordinate_count, i > 0 ? keyframes[i - 1].geometry : null);
                if ((i == 0 && keyframes[i].time != 0) ||
                    (i > 0 && keyframes[i].time <= keyframes[i - 1].time) ||
                    keyframes[i].time > duration + 1e-6) {
                    throw new VectorError.INVALID("Object '%s': keyframe times must start at 0 and increase within the scene", id);
                }
                if (i > 0 && fixed_geometry) {
                    for (int j = 0; j < coordinate_count; j++) {
                        if (keyframes[i].geometry.values[j] != keyframes[0].geometry.values[j]) {
                            fixed_geometry = false;
                            break;
                        }
                    }
                }
            }
            interpolated = new double[coordinate_count];
            if (fixed_geometry) {
                var scratch = new Cairo.RecordingSurface(Cairo.Content.COLOR_ALPHA, null);
                var cr = new Cairo.Context(scratch);
                append_commands(cr, keyframes[0].geometry.values);
                fixed_path = cr.copy_path();
            }
        }

        public void bracket(double time, out int before, out int after, out double alpha) {
            int low = 0;
            int high = keyframes.length - 1;
            while (low < high) {
                int middle = (low + high + 1)/2;
                if (keyframes[middle].time <= time) {
                    low = middle;
                } else {
                    high = middle - 1;
                }
            }
            before = low;
            after = int.min(low + 1, keyframes.length - 1);
            if (before == after || time <= keyframes[before].time) {
                alpha = 0;
            } else {
                alpha = (time - keyframes[before].time)/
                    (keyframes[after].time - keyframes[before].time);
                alpha = double.min(1, double.max(0, alpha));
            }
        }

        private static double mix(double a, double b, double alpha) {
            return a + (b - a)*alpha;
        }

        private void append_commands(Cairo.Context cr, double[] coords) {
            int index = 0;
            double x = 0, y = 0, first_x = 0, first_y = 0;
            for (int i = 0; i < commands.length; i++) {
                switch (commands[i]) {
                case 'M':
                    x = first_x = coords[index++];
                    y = first_y = coords[index++];
                    cr.move_to(x, y);
                    break;
                case 'L':
                    x = coords[index++]; y = coords[index++];
                    cr.line_to(x, y);
                    break;
                case 'C':
                    cr.curve_to(coords[index], coords[index + 1],
                        coords[index + 2], coords[index + 3],
                        coords[index + 4], coords[index + 5]);
                    x = coords[index + 4]; y = coords[index + 5];
                    index += 6;
                    break;
                case 'Q':
                    cr.curve_to(x + (coords[index] - x)*2/3,
                        y + (coords[index + 1] - y)*2/3,
                        coords[index + 2] + (coords[index] - coords[index + 2])*2/3,
                        coords[index + 3] + (coords[index + 1] - coords[index + 3])*2/3,
                        coords[index + 2], coords[index + 3]);
                    x = coords[index + 2]; y = coords[index + 3];
                    index += 4;
                    break;
                case 'Z':
                    cr.close_path(); x = first_x; y = first_y;
                    break;
                }
            }
        }

        public void draw(Cairo.Context cr, double time) {
            int left, right;
            double alpha;
            bracket(time, out left, out right, out alpha);
            var a = keyframes[left];
            var b = keyframes[right];
            double fill_alpha = mix(a.fill[3], b.fill[3], alpha);
            double stroke_alpha = mix(a.stroke[3], b.stroke[3], alpha);
            double width = mix(a.stroke_width, b.stroke_width, alpha);
            if (fill_alpha <= 0 && (stroke_alpha <= 0 || width <= 0)) {
                return;
            }
            cr.new_path();
            if (fixed_path != null) {
                cr.append_path(fixed_path);
            } else {
                for (int i = 0; i < interpolated.length; i++) {
                    interpolated[i] = mix(a.geometry.values[i], b.geometry.values[i], alpha);
                }
                append_commands(cr, interpolated);
            }
            cr.set_fill_rule(fill_rule);
            if (fill_alpha > 0) {
                cr.set_source_rgba(mix(a.fill[0], b.fill[0], alpha),
                    mix(a.fill[1], b.fill[1], alpha), mix(a.fill[2], b.fill[2], alpha), fill_alpha);
                cr.fill_preserve();
            }
            if (stroke_alpha > 0 && width > 0) {
                cr.set_source_rgba(mix(a.stroke[0], b.stroke[0], alpha),
                    mix(a.stroke[1], b.stroke[1], alpha), mix(a.stroke[2], b.stroke[2], alpha), stroke_alpha);
                cr.set_line_width(width);
                cr.stroke();
            } else {
                cr.new_path();
            }
        }
    }

    public class VectorCheckpoint : Object {
        public double time;
        public string label;

        public VectorCheckpoint(Json.Object obj) throws VectorError {
            time = VectorJson.number(VectorJson.member(obj, "time"));
            label = VectorJson.string_node(VectorJson.member(obj, "label"));
        }
    }

    public class VectorScene : Object {
        public string id;
        public double width;
        public double height;
        public double duration;
        public double[] background;
        public VectorCheckpoint[] checkpoints;
        public Gee.ArrayList<VectorObject> objects = new Gee.ArrayList<VectorObject>();

        public VectorScene(Json.Object obj) throws VectorError {
            id = VectorJson.string_node(VectorJson.member(obj, "id"));
            width = VectorJson.number(VectorJson.member(obj, "width"));
            height = VectorJson.number(VectorJson.member(obj, "height"));
            duration = VectorJson.number(VectorJson.member(obj, "duration"));
            background = VectorJson.numbers(VectorJson.member(obj, "background"), 4, true);
            if (id == "" || width <= 0 || height <= 0 || duration <= 0 || duration > 86400 ||
                background[3] != 1) {
                throw new VectorError.INVALID("Scene requires an ID, positive dimensions/duration and an opaque background");
            }
            var steps = VectorJson.array_node(VectorJson.member(obj, "checkpoints"));
            int nsteps = (int) steps.get_length();
            if (nsteps < 2 || nsteps > 10000) {
                throw new VectorError.INVALID("Scene '%s': invalid checkpoint count", id);
            }
            checkpoints = new VectorCheckpoint[nsteps];
            for (int i = 0; i < nsteps; i++) {
                checkpoints[i] = new VectorCheckpoint(VectorJson.object_node(steps.get_element(i)));
                if ((i == 0 && checkpoints[i].time != 0) ||
                    (i > 0 && checkpoints[i].time <= checkpoints[i - 1].time) ||
                    checkpoints[i].time > duration) {
                    throw new VectorError.INVALID("Scene '%s': checkpoints must start at 0 and increase", id);
                }
            }
            if (Math.fabs(checkpoints[nsteps - 1].time - duration) > 1e-6) {
                throw new VectorError.INVALID("Scene '%s': final checkpoint must equal duration", id);
            }
            var paths = VectorJson.array_node(VectorJson.member(obj, "objects"));
            if (paths.get_length() > 20000) {
                throw new VectorError.INVALID("Scene '%s' has too many objects", id);
            }
            var ids = new Gee.HashSet<string>();
            for (uint i = 0; i < paths.get_length(); i++) {
                var path = new VectorObject(VectorJson.object_node(paths.get_element(i)), duration);
                if (!ids.add(path.id)) {
                    throw new VectorError.INVALID("Scene '%s': duplicate object ID '%s'", id, path.id);
                }
                objects.add(path);
            }
            objects.sort((a, b) => a.z < b.z ? -1 : (a.z > b.z ? 1 : 0));
        }

        public int checkpoint_at(double time) {
            int current = 0;
            for (int i = 1; i < checkpoints.length; i++) {
                if (checkpoints[i].time <= time + 1e-6) {
                    current = i;
                } else {
                    break;
                }
            }
            return current;
        }

        public void draw(Cairo.Context cr, double time) {
            cr.save();
            cr.rectangle(0, 0, width, height);
            cr.clip();
            cr.set_source_rgba(background[0], background[1], background[2], background[3]);
            cr.paint();
            cr.set_line_join(Cairo.LineJoin.ROUND);
            cr.set_line_cap(Cairo.LineCap.ROUND);
            time = double.min(duration, double.max(0, time));
            foreach (var path in objects) {
                path.draw(cr, time);
            }
            cr.restore();
        }

        public void draw_fitted(Cairo.Context cr, double time, double width, double height) {
            double scale = double.min(width/this.width, height/this.height);
            cr.save();
            cr.translate((width - this.width*scale)/2, (height - this.height*scale)/2);
            cr.scale(scale, scale);
            draw(cr, time);
            cr.restore();
        }
    }

    public class VectorDeck : Object {
        public Gee.ArrayList<VectorScene> scenes = new Gee.ArrayList<VectorScene>();
        private Gee.HashMap<string, VectorScene> by_id = new Gee.HashMap<string, VectorScene>();

        public VectorDeck(string filename) throws GLib.Error {
            var parser = new Json.Parser();
            parser.load_from_file(filename);
            var root_node = parser.get_root();
            if (root_node == null) {
                throw new VectorError.INVALID("Vector timeline is empty");
            }
            var root = VectorJson.object_node(root_node);
            if (VectorJson.number(VectorJson.member(root, "version")) != 1) {
                throw new VectorError.INVALID("Unsupported vector timeline version");
            }
            var source = VectorJson.array_node(VectorJson.member(root, "scenes"));
            if (source.get_length() < 1 || source.get_length() > 1000) {
                throw new VectorError.INVALID("Invalid scene count");
            }
            for (uint i = 0; i < source.get_length(); i++) {
                var scene = new VectorScene(VectorJson.object_node(source.get_element(i)));
                if (by_id.has_key(scene.id)) {
                    throw new VectorError.INVALID("Duplicate scene ID '%s'", scene.id);
                }
                scenes.add(scene);
                by_id.set(scene.id, scene);
            }
        }

        public VectorScene? find(string id) {
            return by_id.get(id);
        }
    }
}

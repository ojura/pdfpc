// SPDX-License-Identifier: GPL-3.0-or-later
// Deterministic vector export and renderer measurements use the playback renderer.

int main(string[] args) {
    if (args.length < 3) {
        stderr.printf("Usage: vector-probe validate MANIFEST\n" +
            "       vector-probe render MANIFEST SCENE TIME OUTPUT WIDTH HEIGHT\n" +
            "       vector-probe benchmark MANIFEST SCENE WIDTH HEIGHT FRAMES\n");
        return 2;
    }
    try {
        var deck = new pdfpc.VectorDeck(args[2]);
        if (args[1] == "validate") {
            int objects = 0, keyframes = 0;
            foreach (var scene in deck.scenes) {
                objects += scene.objects.size;
                foreach (var path in scene.objects) keyframes += path.keyframes.length;
            }
            stdout.printf("{\"scenes\":%d,\"objects\":%d,\"keyframes\":%d}\n",
                deck.scenes.size, objects, keyframes);
            return 0;
        }
        if (args.length < 4) return 2;
        var scene = deck.find(args[3]);
        if (scene == null) {
            stderr.printf("Unknown scene: %s\n", args[3]);
            return 2;
        }
        if (args[1] == "render" && args.length == 8) {
            double time = double.parse(args[4]);
            int width = int.parse(args[6]), height = int.parse(args[7]);
            if (width < 1 || height < 1 || width > 16384 || height > 16384) return 2;
            Cairo.Surface output;
            if (args[5].has_suffix(".pdf")) {
                output = new Cairo.PdfSurface(args[5], width, height);
            } else if (args[5].has_suffix(".svg")) {
                output = new Cairo.SvgSurface(args[5], width, height);
            } else if (args[5].has_suffix(".png")) {
                output = new Cairo.ImageSurface(Cairo.Format.ARGB32, width, height);
            } else {
                stderr.printf("Output must end in .pdf, .svg or .png\n");
                return 2;
            }
            var cr = new Cairo.Context(output);
            scene.draw_fitted(cr, time, width, height);
            Cairo.Status file_status = Cairo.Status.SUCCESS;
            if (args[5].has_suffix(".png")) file_status = output.write_to_png(args[5]);
            output.finish();
            var status = file_status != Cairo.Status.SUCCESS ? file_status : output.status();
            if (status != Cairo.Status.SUCCESS) {
                stderr.printf("Cairo output failed: %s\n", status.to_string());
                return 1;
            }
            return 0;
        }
        if (args[1] == "benchmark" && args.length == 7) {
            int width = int.parse(args[4]), height = int.parse(args[5]);
            int frames = int.parse(args[6]);
            if (frames < 10 || frames > 100000 || width < 1 || height < 1 ||
                width > 16384 || height > 16384) return 2;
            var image = new Cairo.ImageSurface(Cairo.Format.ARGB32, width, height);
            var cr = new Cairo.Context(image);
            var samples = new Gee.ArrayList<double?>();
            double total = 0;
            for (int i = -30; i < frames; i++) {
                double time = scene.duration*(i < 0 ? 0 : i)/(frames - 1);
                int64 begin = GLib.get_monotonic_time();
                scene.draw_fitted(cr, time, width, height);
                image.flush();
                double elapsed = (GLib.get_monotonic_time() - begin)/1000.0;
                if (i >= 0) { samples.add(elapsed); total += elapsed; }
            }
            samples.sort((a,b) => a < b ? -1 : (a > b ? 1 : 0));
            var report = new Json.Object();
            report.set_string_member("scene", scene.id);
            report.set_int_member("width", width);
            report.set_int_member("height", height);
            report.set_int_member("frames", frames);
            report.set_double_member("mean_ms", total/frames);
            report.set_double_member("p50_ms", (double) samples[frames/2]);
            report.set_double_member("p95_ms", (double) samples[(int)(frames*0.95)]);
            report.set_double_member("p99_ms", (double) samples[(int)(frames*0.99)]);
            report.set_double_member("max_ms", (double) samples[frames - 1]);
            if (total > 0) report.set_double_member("mean_capacity_fps", frames*1000/total);
            else report.set_null_member("mean_capacity_fps");
            var result = new Json.Node(Json.NodeType.OBJECT);
            result.set_object(report);
            stdout.printf("%s\n", Json.to_string(result, false));
            return 0;
        }
        stderr.printf("Invalid command or arguments\n");
        return 2;
    } catch (GLib.Error error) {
        stderr.printf("%s\n", error.message);
        return 1;
    }
}

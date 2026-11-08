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
            if (args[5].has_suffix(".png")) output.write_to_png(args[5]);
            output.finish();
            if (output.status() != Cairo.Status.SUCCESS) {
                stderr.printf("Cairo output failed: %s\n", output.status().to_string());
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
            stdout.printf("{\"scene\":\"%s\",\"width\":%d,\"height\":%d,\"frames\":%d," +
                "\"mean_ms\":%.4f,\"p50_ms\":%.4f,\"p95_ms\":%.4f,\"p99_ms\":%.4f," +
                "\"max_ms\":%.4f,\"mean_capacity_fps\":%.2f}\n",
                scene.id, width, height, frames, total/frames, (double) samples[frames/2],
                (double) samples[(int)(frames*0.95)], (double) samples[(int)(frames*0.99)],
                (double) samples[frames - 1], frames*1000/total);
            return 0;
        }
        stderr.printf("Invalid command or arguments\n");
        return 2;
    } catch (GLib.Error error) {
        stderr.printf("%s\n", error.message);
        return 1;
    }
}

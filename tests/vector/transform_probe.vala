// SPDX-License-Identifier: GPL-3.0-or-later
// Compare the production PDF renderer and vector binding in the same viewport.
int main(string[] args) {
    if (args.length != 8) return 2;
    new pdfpc.Options();
    pdfpc.Options.no_install = true;
    var metadata = new pdfpc.Metadata.Pdf(args[1]);
    metadata.set_notes_position(pdfpc.Metadata.NotesPosition.from_string(args[3]));
    int width = int.parse(args[4]), height = int.parse(args[5]);
    pdfpc.PresentationController.ScaledRectangle? zoom = null;
    if (args[6] != "none") {
        var values = args[6].split(",");
        if (values.length != 4) return 2;
        zoom = new pdfpc.PresentationController.ScaledRectangle();
        zoom.x = double.parse(values[0]); zoom.y = double.parse(values[1]);
        zoom.width = double.parse(values[2]); zoom.height = double.parse(values[3]);
    }
    try {
        var pdf = metadata.renderer.render(0, false, width, height, false, false, zoom);
        var page = metadata.document.get_page(0);
        double full_width, full_height;
        page.get_size(out full_width, out full_height);
        var deck = new pdfpc.VectorDeck(args[2]);
        pdfpc.VectorBinding? binding = null;
        foreach (var link in page.get_link_mapping()) {
            if (link.action.type == Poppler.ActionType.URI &&
                link.action.uri.uri == "pdfpc-vector:registration") {
                binding = new pdfpc.VectorBinding(deck.find("registration"), link.area,
                    0, full_width, full_height);
            }
        }
        if (binding == null) return 2;
        var vector = new Cairo.ImageSurface(Cairo.Format.RGB24, width, height);
        var context = new Cairo.Context(vector);
        context.set_source_rgb(1, 1, 1); context.paint();
        binding.draw(context, metadata, 0, width, height, zoom);
        if (pdf.write_to_png(args[7] + "-pdf.png") != Cairo.Status.SUCCESS ||
            vector.write_to_png(args[7] + "-vector.png") != Cairo.Status.SUCCESS) return 1;
        return 0;
    } catch (GLib.Error error) {
        printerr("%s\n", error.message);
        return 1;
    }
}

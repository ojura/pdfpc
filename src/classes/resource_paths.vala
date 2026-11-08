// SPDX-License-Identifier: GPL-3.0-or-later

namespace pdfpc.Paths {
    // Packaged applications can relocate resources without recompiling them.
    public string get_data_dir(bool no_install) {
        var directory = Environment.get_variable("PDFPC_DATA_DIR");
        if (directory != null && directory.length > 0) {
            return directory;
        }
        return no_install ? SOURCE_PATH : SHARE_PATH;
    }

    public string get_config_dir(bool no_install) {
        var directory = Environment.get_variable("PDFPC_CONFIG_DIR");
        if (directory != null && directory.length > 0) {
            return directory;
        }
        return no_install ? Path.build_filename(SOURCE_PATH, "rc") : CONF_PATH;
    }
}

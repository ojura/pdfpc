namespace pdfpc {
    class Resources {
        // `bin` directory
        private static string executable_dir = "";

        public static void init(string path) {
            executable_dir = Path.get_dirname(path);
        }

        public static string resolve(string resource) {
            var directory = Environment.get_variable("PDFPC_DATA_DIR");
            if (directory != null && directory.length > 0) {
                return Path.build_filename(directory, resource);
            }
#if WIN32
            var local_path = Path.build_filename(executable_dir, "../share/pdfpc", resource);
            if (GLib.FileUtils.test(local_path, GLib.FileTest.EXISTS)) {
                return local_path;
            }
#endif

            if (Options.no_install) {
                return Path.build_filename(Paths.SOURCE_PATH, resource);
            } else {
                return Path.build_filename(Paths.SHARE_PATH, resource);
            }
        }

        public static string resolve_system_config() {
            var directory = Environment.get_variable("PDFPC_CONFIG_DIR");
            if (directory != null && directory.length > 0) {
                return Path.build_filename(directory, "pdfpcrc");
            }
#if WIN32
            var local_path = Path.build_filename(executable_dir, "..", "etc", "pdfpcrc");
            if (GLib.FileUtils.test(local_path, GLib.FileTest.EXISTS)) {
                return local_path;
            }
#endif

            if (Options.no_install) {
                return Path.build_filename(Paths.SOURCE_PATH, "rc/pdfpcrc");
            } else {
                return Path.build_filename(Paths.CONF_PATH, "pdfpcrc");
            }
        }
    }
}

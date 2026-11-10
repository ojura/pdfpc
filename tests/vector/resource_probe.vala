// SPDX-License-Identifier: GPL-3.0-or-later
// Exercise the production resource resolver with explicit build-time paths.
namespace pdfpc {
    namespace Options {
        public bool no_install = false;
    }
    namespace Paths {
        public const string SOURCE_PATH = "configured-source";
        public const string SHARE_PATH = "configured-share";
        public const string CONF_PATH = "configured-config";
    }
}

int main(string[] args) {
    if (args.length != 4) return 2;
    pdfpc.Resources.init(args[1]);
    pdfpc.Options.no_install = args[2] == "source";
    print("%s\n%s\n", pdfpc.Resources.resolve(args[3]),
        pdfpc.Resources.resolve_system_config());
    return 0;
}

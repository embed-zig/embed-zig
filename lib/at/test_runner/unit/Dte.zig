pub fn make(comptime lib: type) @import("testing").TestRunner {
    return @import("../../Dte.zig").TestRunner(lib);
}

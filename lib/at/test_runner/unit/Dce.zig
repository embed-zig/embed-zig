pub fn make(comptime lib: type) @import("testing").TestRunner {
    return @import("../../Dce.zig").TestRunner(lib);
}

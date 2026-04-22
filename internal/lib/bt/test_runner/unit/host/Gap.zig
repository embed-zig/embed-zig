const gap_mod = @import("../../../host/Gap.zig");

pub fn make(comptime lib: type) @import("testing").TestRunner {
    return gap_mod.TestRunner(lib);
}

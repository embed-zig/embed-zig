const att = @import("../../../host/att.zig");

pub fn make(comptime lib: type) @import("testing").TestRunner {
    return att.TestRunner(lib);
}

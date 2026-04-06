const write_mod = @import("../../../../host/xfer/write.zig");

pub fn make(comptime lib: type) @import("testing").TestRunner {
    return write_mod.TestRunner(lib);
}

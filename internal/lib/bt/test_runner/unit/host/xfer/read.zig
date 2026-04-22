const read_mod = @import("../../../../host/xfer/read.zig");

pub fn make(comptime lib: type) @import("testing").TestRunner {
    return read_mod.TestRunner(lib);
}

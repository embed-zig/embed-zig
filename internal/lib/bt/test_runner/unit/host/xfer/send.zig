const send_mod = @import("../../../../host/xfer/send.zig");

pub fn make(comptime lib: type) @import("testing").TestRunner {
    return send_mod.TestRunner(lib);
}

const receiver_mod = @import("../../../../host/server/Receiver.zig");

pub fn make(comptime lib: type) @import("testing").TestRunner {
    return receiver_mod.TestRunner(lib);
}

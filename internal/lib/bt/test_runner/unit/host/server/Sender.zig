const sender_mod = @import("../../../../host/server/Sender.zig");

pub fn make(comptime lib: type) @import("testing").TestRunner {
    return sender_mod.TestRunner(lib);
}

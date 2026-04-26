const glib = @import("glib");

const Chunk = @import("../../../../host/xfer/Chunk.zig");

pub fn make(comptime lib: type) glib.testing.TestRunner {
    return Chunk.TestRunner(lib);
}

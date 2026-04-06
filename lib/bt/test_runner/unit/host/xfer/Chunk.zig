const Chunk = @import("../../../../host/xfer/Chunk.zig");

pub fn make(comptime lib: type) @import("testing").TestRunner {
    return Chunk.TestRunner(lib);
}

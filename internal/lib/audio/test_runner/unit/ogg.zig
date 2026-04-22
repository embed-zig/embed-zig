const stdz = @import("stdz");
const testing_api = @import("testing");

const types_mod = @import("../../ogg/types.zig");
const crc_mod = @import("../../ogg/crc.zig");
const pack_buffer_mod = @import("../../ogg/PackBuffer.zig");
const page_mod = @import("../../ogg/Page.zig");
const packet_mod = @import("../../ogg/Packet.zig");
const stream_mod = @import("../../ogg/Stream.zig");
const sync_mod = @import("../../ogg/Sync.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: stdz.mem.Allocator) bool {
            _ = self;
            _ = allocator;
            t.run("types", types_mod.TestRunner(lib));
            t.run("crc", crc_mod.TestRunner(lib));
            t.run("PackBuffer", pack_buffer_mod.TestRunner(lib));
            t.run("Page", page_mod.TestRunner(lib));
            t.run("Packet", packet_mod.TestRunner(lib));
            t.run("Stream", stream_mod.TestRunner(lib));
            t.run("Sync", sync_mod.TestRunner(lib));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: stdz.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}

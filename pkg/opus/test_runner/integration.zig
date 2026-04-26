const testing_api = @import("testing");
const version = @import("integration/version.zig");
const i16_48k_1ch_5s = @import("integration/i16_48k_1ch_5s.zig");
const i16_48k_2ch_2s = @import("integration/i16_48k_2ch_2s.zig");
const i16_24k_1ch_1s = @import("integration/i16_24k_1ch_1s.zig");
const i16_16k_1ch_2s = @import("integration/i16_16k_1ch_2s.zig");
const f32_48k_1ch_2s = @import("integration/f32_48k_1ch_2s.zig");
const f32_48k_2ch_2s = @import("integration/f32_48k_2ch_2s.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("version", version.make(lib));
            t.run("i16_48k_1ch_5s", i16_48k_1ch_5s.make(lib));
            t.run("i16_48k_2ch_2s", i16_48k_2ch_2s.make(lib));
            t.run("i16_24k_1ch_1s", i16_24k_1ch_1s.make(lib));
            t.run("i16_16k_1ch_2s", i16_16k_1ch_2s.make(lib));
            t.run("f32_48k_1ch_2s", f32_48k_1ch_2s.make(lib));
            t.run("f32_48k_2ch_2s", f32_48k_2ch_2s.make(lib));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}

const glib = @import("glib");
const version = @import("integration/version.zig");
const i16_48k_1ch_5s = @import("integration/i16_48k_1ch_5s.zig");
const i16_48k_2ch_2s = @import("integration/i16_48k_2ch_2s.zig");
const i16_24k_1ch_1s = @import("integration/i16_24k_1ch_1s.zig");
const i16_16k_1ch_2s = @import("integration/i16_16k_1ch_2s.zig");
const f32_48k_1ch_2s = @import("integration/f32_48k_1ch_2s.zig");
const f32_48k_2ch_2s = @import("integration/f32_48k_2ch_2s.zig");

pub fn make(comptime grt: type) glib.testing.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("version", version.make(grt));
            t.run("i16_48k_1ch_5s", i16_48k_1ch_5s.make(grt));
            t.run("i16_48k_2ch_2s", i16_48k_2ch_2s.make(grt));
            t.run("i16_24k_1ch_1s", i16_24k_1ch_1s.make(grt));
            t.run("i16_16k_1ch_2s", i16_16k_1ch_2s.make(grt));
            t.run("f32_48k_1ch_2s", f32_48k_1ch_2s.make(grt));
            t.run("f32_48k_2ch_2s", f32_48k_2ch_2s.make(grt));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}

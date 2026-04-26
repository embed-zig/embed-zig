const glib = @import("glib");

const Context = @import("../../event/Context.zig");
const EventReceiver = @import("../../event/EventReceiver.zig");
const zux_event = @import("../../event.zig");

pub fn make(comptime grt: type) glib.testing.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            const TestCase = struct {
                fn event_union_requires_source_id_except_tick() !void {
                    inline for (@typeInfo(zux_event.Event).@"union".fields) |field| {
                        if (field.type.kind == .tick) continue;
                        try grt.std.testing.expect(@hasField(field.type, "source_id"));
                        try grt.std.testing.expect(@FieldType(field.type, "source_id") == u32);
                    }
                }
            };

            t.parallel();
            t.run("Context", Context.TestRunner(grt));
            t.run("EventReceiver", EventReceiver.TestRunner(grt));
            TestCase.event_union_requires_source_id_except_tick() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
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

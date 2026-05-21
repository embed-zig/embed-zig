const glib = @import("glib");

const CustomRegistar = @import("../../event/CustomRegistar.zig");
const EventReceiver = @import("../../event/EventReceiver.zig");
const zux_event = @import("../../event.zig");

pub fn make(comptime grt: type) glib.testing.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(runner: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = runner;

            const TestCase = struct {
                fn event_union_requires_source_id_except_tick() !void {
                    inline for (@typeInfo(zux_event.Event).@"union".fields) |field| {
                        if (field.type.kind == .tick) continue;
                        try grt.std.testing.expect(@hasField(field.type, "source_id"));
                        try grt.std.testing.expect(@FieldType(field.type, "source_id") == u32);
                    }
                }

                fn custom_event_borrows_payload_and_runs_vtable_deinit(test_allocator: glib.std.mem.Allocator) !void {
                    var deinit_count: u32 = 0;

                    const Payload = struct {
                        pub const event_name = "test.payload";

                        allocator: glib.std.mem.Allocator,
                        deinit_count: *u32,
                        value: u32,

                        pub fn decodeJson(json_allocator: glib.std.mem.Allocator, value: glib.std.json.Value) !*@This() {
                            _ = json_allocator;
                            _ = value;
                            unreachable;
                        }

                        pub fn deinit(self: *@This()) void {
                            self.deinit_count.* += 1;
                            self.allocator.destroy(self);
                        }
                    };

                    const OtherPayload = struct {
                        pub fn deinit(_: *@This()) void {}
                    };

                    const payload = try test_allocator.create(Payload);
                    payload.* = .{
                        .allocator = test_allocator,
                        .deinit_count = &deinit_count,
                        .value = 42,
                    };

                    const Registar = zux_event.CustomRegistar.make(.{Payload});
                    const custom = Registar.init().initEvent(Payload, 7, payload);
                    try grt.std.testing.expectEqual(@as(u32, 7), custom.source_id);
                    try grt.std.testing.expectEqual(@as(u32, 0), custom.register_id);
                    try grt.std.testing.expect(custom.is(Payload));
                    try grt.std.testing.expect(!custom.is(OtherPayload));
                    try grt.std.testing.expectEqual(@as(u32, 42), (try custom.as(Payload)).value);
                    try grt.std.testing.expectError(error.TypeMismatch, custom.as(OtherPayload));

                    custom.deinit();
                    try grt.std.testing.expectEqual(@as(u32, 1), deinit_count);
                }
            };

            t.parallel();
            t.run("CustomRegistar", CustomRegistar.TestRunner(grt));
            t.run("EventReceiver", EventReceiver.TestRunner(grt));
            TestCase.event_union_requires_source_id_except_tick() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.custom_event_borrows_payload_and_runs_vtable_deinit(allocator) catch |err| {
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

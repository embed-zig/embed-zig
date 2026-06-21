const glib = @import("glib");

const harness_mod = @import("harness.zig");
const read_mod = @import("../../../host/xfer/read.zig");
const send_mod = @import("../../../host/xfer/send.zig");

pub fn make(comptime grt: type) glib.testing.TestRunner {
    const Runner = struct {
        task_options: glib.task.Options = .{ .min_stack_size = 96 * 1024 },
        xfer_task_options: glib.task.Options = .{ .min_stack_size = 64 * 1024 },

        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = t;
            runCase(grt, allocator, self.xfer_task_options) catch return false;
            return true;
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

pub fn run(comptime grt: type, allocator: glib.std.mem.Allocator) !void {
    try runCase(grt, allocator, .{ .min_stack_size = 64 * 1024 });
}

fn runCase(comptime grt: type, allocator: glib.std.mem.Allocator, task_options: glib.task.Options) !void {
    const Harness = harness_mod.make(grt);

    var harness = try Harness.init(allocator);
    defer harness.deinit();

    var expected: [96]u8 = undefined;
    harness_mod.fillPattern(&expected, 0x21);

    const ReadTask = struct {
        allocator: glib.std.mem.Allocator,
        transport: Harness.Endpoint,
        result: ?[]u8 = null,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            self.result = read_mod.read(grt, self.allocator, &self.transport, .{
                .att_mtu = 23,
                .timeout = 20 * glib.time.duration.MilliSecond,
                .max_timeout_retries = 3,
            }) catch |err| {
                self.err = err;
                return;
            };
        }
    };

    const SendTask = struct {
        allocator: glib.std.mem.Allocator,
        transport: Harness.Endpoint,
        err: ?anyerror = null,

        fn dataFn(
            _: ?*anyopaque,
            payload_allocator: glib.std.mem.Allocator,
            conn_handle: u16,
            service_uuid: u16,
            char_uuid: u16,
        ) ![]u8 {
            if (conn_handle != harness_mod.test_conn_handle) return error.UnexpectedConnHandle;
            if (service_uuid != harness_mod.test_service_uuid) return error.UnexpectedServiceUuid;
            if (char_uuid != harness_mod.test_char_uuid) return error.UnexpectedCharUuid;

            var payload: [96]u8 = undefined;
            harness_mod.fillPattern(&payload, 0x21);
            return payload_allocator.dupe(u8, &payload);
        }

        fn run(self: *@This()) void {
            send_mod.send(grt, self.allocator, &self.transport, null, dataFn, .{
                .att_mtu = 23,
                .timeout = 20 * glib.time.duration.MilliSecond,
                .send_redundancy = 1,
                .max_timeout_retries = 3,
            }) catch |err| {
                self.err = err;
                return;
            };
        }
    };

    var read_task = ReadTask{
        .allocator = allocator,
        .transport = harness.left(),
    };
    var send_task = SendTask{
        .allocator = allocator,
        .transport = harness.right(),
    };

    const read_task_handle = try grt.task.go("testing/bt/xfer/read", task_options, glib.task.Routine.init(&read_task, ReadTask.run));
    const send_task_handle = try grt.task.go("testing/bt/xfer/send", task_options, glib.task.Routine.init(&send_task, SendTask.run));
    read_task_handle.join();
    send_task_handle.join();

    try grt.std.testing.expect(read_task.err == null);
    try grt.std.testing.expect(send_task.err == null);
    const result = read_task.result orelse return error.MissingReadResult;
    defer allocator.free(result);
    try grt.std.testing.expectEqualSlices(u8, &expected, result);
}

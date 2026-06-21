const glib = @import("glib");

const harness_mod = @import("harness.zig");
const write_mod = @import("../../../host/xfer/write.zig");
const recv_mod = @import("../../../host/xfer/recv.zig");

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

    var expected: [128]u8 = undefined;
    harness_mod.fillPattern(&expected, 0x74);

    const WriteTask = struct {
        allocator: glib.std.mem.Allocator,
        transport: Harness.Endpoint,
        expected: []const u8,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            write_mod.write(grt, self.allocator, &self.transport, self.expected, .{
                .att_mtu = 23,
                .timeout = 20 * glib.time.duration.MilliSecond,
                .send_redundancy = 1,
                .max_timeout_retries = 4,
            }) catch |err| {
                self.err = err;
                return;
            };
        }
    };

    const RecvTask = struct {
        allocator: glib.std.mem.Allocator,
        transport: Harness.Endpoint,
        result: ?[]u8 = null,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            self.result = recv_mod.recv(grt, self.allocator, &self.transport, .{
                .att_mtu = 23,
                .timeout = 20 * glib.time.duration.MilliSecond,
                .max_timeout_retries = 4,
            }) catch |err| {
                self.err = err;
                return;
            };
        }
    };

    var client = harness.left();
    client.drop_seq_once = 2;
    var write_task = WriteTask{
        .allocator = allocator,
        .transport = client,
        .expected = &expected,
    };
    var recv_task = RecvTask{
        .allocator = allocator,
        .transport = harness.right(),
    };

    const write_task_handle = try grt.task.go("testing/bt/xfer/write", task_options, glib.task.Routine.init(&write_task, WriteTask.run));
    const recv_task_handle = try grt.task.go("testing/bt/xfer/recv", task_options, glib.task.Routine.init(&recv_task, RecvTask.run));
    write_task_handle.join();
    recv_task_handle.join();

    try grt.std.testing.expect(write_task.err == null);
    try grt.std.testing.expect(recv_task.err == null);
    try grt.std.testing.expect(write_task.transport.dropped);
    const result = recv_task.result orelse return error.MissingRecvResult;
    defer allocator.free(result);
    try grt.std.testing.expectEqualSlices(u8, &expected, result);
}

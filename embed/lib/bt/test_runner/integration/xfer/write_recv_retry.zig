const glib = @import("glib");

const harness_mod = @import("harness.zig");
const write_mod = @import("../../../host/xfer/write.zig");
const recv_mod = @import("../../../host/xfer/recv.zig");

pub fn make(comptime grt: type) glib.testing.TestRunner {
    return glib.testing.TestRunner.fromFn(grt.std, 96 * 1024, struct {
        fn run(t: *glib.testing.T, allocator: glib.std.mem.Allocator) !void {
            _ = t;
            try runCase(grt, allocator);
        }
    }.run);
}

pub fn run(comptime grt: type, allocator: glib.std.mem.Allocator) !void {
    try runCase(grt, allocator);
}

fn runCase(comptime grt: type, allocator: glib.std.mem.Allocator) !void {
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

    const write_thread = try grt.std.Thread.spawn(.{}, WriteTask.run, .{&write_task});
    const recv_thread = try grt.std.Thread.spawn(.{}, RecvTask.run, .{&recv_task});
    write_thread.join();
    recv_thread.join();

    try grt.std.testing.expect(write_task.err == null);
    try grt.std.testing.expect(recv_task.err == null);
    try grt.std.testing.expect(write_task.transport.dropped);
    const result = recv_task.result orelse return error.MissingRecvResult;
    defer allocator.free(result);
    try grt.std.testing.expectEqualSlices(u8, &expected, result);
}

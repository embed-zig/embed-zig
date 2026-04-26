const glib = @import("glib");

const harness_mod = @import("harness.zig");
const read_mod = @import("../../../host/xfer/read.zig");
const send_mod = @import("../../../host/xfer/send.zig");

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
    harness_mod.fillPattern(&expected, 0x53);

    const ReadTask = struct {
        allocator: glib.std.mem.Allocator,
        transport: Harness.Endpoint,
        result: ?[]u8 = null,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            self.result = read_mod.read(grt, self.allocator, &self.transport, .{
                .att_mtu = 23,
                .timeout_ms = 20,
                .max_timeout_retries = 4,
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

            var payload: [128]u8 = undefined;
            harness_mod.fillPattern(&payload, 0x53);
            return payload_allocator.dupe(u8, &payload);
        }

        fn run(self: *@This()) void {
            send_mod.send(grt, self.allocator, &self.transport, null, dataFn, .{
                .att_mtu = 23,
                .timeout_ms = 20,
                .send_redundancy = 1,
                .max_timeout_retries = 4,
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
    var server = harness.right();
    server.drop_seq_once = 2;
    var send_task = SendTask{
        .allocator = allocator,
        .transport = server,
    };

    const read_thread = try grt.std.Thread.spawn(.{}, ReadTask.run, .{&read_task});
    const send_thread = try grt.std.Thread.spawn(.{}, SendTask.run, .{&send_task});
    read_thread.join();
    send_thread.join();

    try grt.std.testing.expect(read_task.err == null);
    try grt.std.testing.expect(send_task.err == null);
    try grt.std.testing.expect(send_task.transport.dropped);
    const result = read_task.result orelse return error.MissingReadResult;
    defer allocator.free(result);
    try grt.std.testing.expectEqualSlices(u8, &expected, result);
}

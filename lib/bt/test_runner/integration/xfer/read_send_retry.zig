const embed = @import("embed");
const testing_api = @import("testing");
const harness_mod = @import("harness.zig");
const read_mod = @import("../../../host/xfer/read.zig");
const send_mod = @import("../../../host/xfer/send.zig");

pub fn make(comptime lib: type, comptime Channel: fn (type) type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            runCase(lib, Channel, allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}

pub fn run(comptime lib: type, comptime Channel: fn (type) type, allocator: lib.mem.Allocator) !void {
    try runCase(lib, Channel, allocator);
}

fn runCase(comptime lib: type, comptime Channel: fn (type) type, allocator: lib.mem.Allocator) !void {
    const testing = lib.testing;
    const Harness = harness_mod.make(lib, Channel);

    var harness = try Harness.init(allocator);
    defer harness.deinit();

    var expected: [128]u8 = undefined;
    harness_mod.fillPattern(&expected, 0x53);

    const ReadTask = struct {
        allocator: lib.mem.Allocator,
        transport: Harness.Endpoint,
        result: ?[]u8 = null,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            self.result = read_mod.read(lib, self.allocator, &self.transport, .{
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
        allocator: lib.mem.Allocator,
        transport: Harness.Endpoint,
        err: ?anyerror = null,

        fn dataFn(
            payload_allocator: embed.mem.Allocator,
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
            send_mod.send(lib, self.allocator, &self.transport, dataFn, .{
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

    const read_thread = try lib.Thread.spawn(.{}, ReadTask.run, .{&read_task});
    const send_thread = try lib.Thread.spawn(.{}, SendTask.run, .{&send_task});
    read_thread.join();
    send_thread.join();

    try testing.expect(read_task.err == null);
    try testing.expect(send_task.err == null);
    try testing.expect(send_task.transport.dropped);
    const result = read_task.result orelse return error.MissingReadResult;
    defer allocator.free(result);
    try testing.expectEqualSlices(u8, &expected, result);
}

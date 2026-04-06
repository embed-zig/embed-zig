const embed = @import("embed");
const testing_api = @import("testing");
const harness_mod = @import("harness.zig");
const write_mod = @import("../../../host/xfer/write.zig");
const recv_mod = @import("../../../host/xfer/recv.zig");

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
    harness_mod.fillPattern(&expected, 0x74);

    const WriteTask = struct {
        allocator: lib.mem.Allocator,
        transport: Harness.Endpoint,
        expected: []const u8,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            write_mod.write(lib, self.allocator, &self.transport, self.expected, .{
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

    const RecvTask = struct {
        allocator: lib.mem.Allocator,
        transport: Harness.Endpoint,
        result: ?[]u8 = null,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            self.result = recv_mod.recv(lib, self.allocator, &self.transport, .{
                .att_mtu = 23,
                .timeout_ms = 20,
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

    const write_thread = try lib.Thread.spawn(.{}, WriteTask.run, .{&write_task});
    const recv_thread = try lib.Thread.spawn(.{}, RecvTask.run, .{&recv_task});
    write_thread.join();
    recv_thread.join();

    try testing.expect(write_task.err == null);
    try testing.expect(recv_task.err == null);
    try testing.expect(write_task.transport.dropped);
    const result = recv_task.result orelse return error.MissingRecvResult;
    defer allocator.free(result);
    try testing.expectEqualSlices(u8, &expected, result);
}

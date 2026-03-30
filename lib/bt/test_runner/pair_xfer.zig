//! Pair xfer test runner — exercises host-side xfer as two peers.
//!
//! This runner models the real deployment shape:
//! - one side runs the xfer client flow
//! - the other side runs the xfer server flow
//!
//! On hardware these would run on two different boards/processes.
//! For local tests, a mock HCI system can run both in one process.

const embed = @import("embed");
const bt = @import("../../bt.zig");
const Central = @import("../Central.zig");
const Peripheral = @import("../Peripheral.zig");
const Chunk = @import("../host/xfer/Chunk.zig");
const testing_api = @import("testing");

const device_name = "PairXfer";
const service_uuid: u16 = 0x180D;
const plain_char_uuid: u16 = 0x2A57;
const mux_char_uuid: u16 = 0x2A58;
const negotiated_mtu: u16 = 64;
const topic_alpha: Chunk.Topic = 0x0102030405060708;
const topic_beta: Chunk.Topic = 0x1112131415161718;
const topic_missing: Chunk.Topic = 0x2122232425262728;
const timeout_ms: u32 = 5000;
const reconnect_timeout_ms: u32 = 10000;

pub fn makeCentral(comptime lib: type, host: anytype) testing_api.TestRunner {
    const HostPtr = @TypeOf(host);
    comptime requireHostPointer(HostPtr);

    const Runner = struct {
        host: HostPtr,

        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: embed.mem.Allocator) bool {
            runCentralRole(lib, self.host, allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = allocator;
            lib.testing.allocator.destroy(self);
        }
    };

    const runner = lib.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{ .host = host };
    return testing_api.TestRunner.make(Runner).new(runner);
}

pub fn makePeripheral(comptime lib: type, host: anytype) testing_api.TestRunner {
    const HostPtr = @TypeOf(host);
    comptime requireHostPointer(HostPtr);

    const Runner = struct {
        host: HostPtr,

        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: embed.mem.Allocator) bool {
            runPeripheralRole(lib, self.host, allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = allocator;
            lib.testing.allocator.destroy(self);
        }
    };

    const runner = lib.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{ .host = host };
    return testing_api.TestRunner.make(Runner).new(runner);
}

fn runCentralRole(comptime lib: type, host: anytype, allocator: embed.mem.Allocator) !void {
    const testing = lib.testing;

    const State = struct {
        mutex: lib.Thread.Mutex = .{},
        found: bool = false,
        addr: Central.BdAddr = .{0} ** 6,
        addr_type: Central.AddrType = .public,
        disconnected_count: u32 = 0,
    };

    const Hook = struct {
        fn cb(ctx: ?*anyopaque, evt: Central.CentralEvent) void {
            const state: *State = @ptrCast(@alignCast(ctx.?));
            state.mutex.lock();
            defer state.mutex.unlock();

            switch (evt) {
                .device_found => |report| {
                    if (!state.found) {
                        state.found = true;
                        state.addr = report.addr;
                        state.addr_type = report.addr_type;
                    }
                },
                .disconnected => |_| {
                    state.disconnected_count += 1;
                },
                else => {},
            }
        }
    };

    var state = State{};
    const central = host.central();
    try central.start();
    defer central.stop();
    const client = host.client();
    central.addEventHook(@ptrCast(&state), Hook.cb);
    defer central.removeEventHook(@ptrCast(&state), Hook.cb);

    const found = try discoverPeer(lib, central, &state);
    var conn = try client.connect(found.addr, found.addr_type, .{});
    runPrimaryClientSession(lib, &conn, allocator) catch |err| {
        conn.disconnect();
        return err;
    };
    conn.disconnect();
    try waitForDisconnectCount(lib, &state, 1, timeout_ms);

    const found_again = try discoverPeer(lib, central, &state);
    var conn_again = try client.connect(found_again.addr, found_again.addr_type, .{});
    runReconnectClientSession(lib, &conn_again, allocator) catch |err| {
        conn_again.disconnect();
        return err;
    };
    conn_again.disconnect();
    try waitForDisconnectCount(lib, &state, 2, timeout_ms);

    try testing.expectEqual(@as(u32, 2), state.disconnected_count);
}

fn runPeripheralRole(comptime lib: type, host: anytype, allocator: embed.mem.Allocator) !void {
    const testing = lib.testing;
    const server = host.server();
    const peripheral = host.peripheral();
    const ServerType = @TypeOf(server.*);
    const ReadXRequest = ServerType.ReadXRequest;
    const WriteXRequest = ServerType.WriteXRequest;
    const ReadXResponseWriter = ServerType.ReadXResponseWriter;
    const MuxRequest = ServerType.ServerMux.Request;

    const State = struct {
        mutex: lib.Thread.Mutex = .{},
        connected_count: u32 = 0,
        disconnected_count: u32 = 0,
        conn_handle: u16 = 0,
        read_calls: usize = 0,
        write_calls: usize = 0,
        alpha_calls: usize = 0,
        beta_calls: usize = 0,
        last_topic: ?Chunk.Topic = null,
        read_value: [600]u8 = undefined,
        write_value: [600]u8 = undefined,
        write_len: usize = 0,

        fn init() @This() {
            var self = @This(){};
            fillReadPayload(&self.read_value);
            return self;
        }

        fn onEvent(ctx: ?*anyopaque, evt: Peripheral.PeripheralEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.mutex.lock();
            defer self.mutex.unlock();

            switch (evt) {
                .connected => |info| {
                    self.connected_count += 1;
                    self.conn_handle = info.conn_handle;
                },
                .disconnected => |_| {
                    self.disconnected_count += 1;
                    self.conn_handle = 0;
                },
                else => {},
            }
        }

        fn handleRead(ctx: ?*anyopaque, req: *const ReadXRequest, rw: *ReadXResponseWriter) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            _ = req;
            self.mutex.lock();
            defer self.mutex.unlock();
            self.read_calls += 1;
            rw.write(&self.read_value);
        }

        fn handleWrite(ctx: ?*anyopaque, req: *const WriteXRequest) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.mutex.lock();
            defer self.mutex.unlock();
            self.write_calls += 1;
            self.write_len = @min(self.write_value.len, req.data.len);
            @memcpy(self.write_value[0..self.write_len], req.data[0..self.write_len]);
        }

        fn handleAlpha(ctx: ?*anyopaque, req: *const MuxRequest, rw: *ReadXResponseWriter) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.mutex.lock();
            defer self.mutex.unlock();
            self.alpha_calls += 1;
            self.last_topic = req.topic;
            rw.write("alpha");
        }

        fn handleBeta(ctx: ?*anyopaque, req: *const MuxRequest, rw: *ReadXResponseWriter) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.mutex.lock();
            defer self.mutex.unlock();
            self.beta_calls += 1;
            self.last_topic = req.topic;
            rw.write("beta");
        }
    };

    const chars = [_]bt.Peripheral.CharDef{
        bt.Peripheral.Char(plain_char_uuid, .{
            .write = true,
            .write_without_response = true,
            .notify = true,
        }),
        bt.Peripheral.Char(mux_char_uuid, .{
            .write = true,
            .write_without_response = true,
            .notify = true,
        }),
    };
    const services = [_]bt.Peripheral.ServiceDef{
        bt.Peripheral.Service(service_uuid, &chars),
    };

    var state = State.init();
    peripheral.addEventHook(&state, State.onEvent);
    defer peripheral.removeEventHook(&state, State.onEvent);

    var mux = ServerType.ServerMux.init(allocator);
    defer mux.deinit();

    server.setConfig(.{ .services = &services });
    try server.handleX(service_uuid, plain_char_uuid, .{
        .read = State.handleRead,
        .write = State.handleWrite,
    }, &state);
    try mux.handle(topic_alpha, State.handleAlpha, &state);
    try mux.handle(topic_beta, State.handleBeta, &state);
    try server.handleX(service_uuid, mux_char_uuid, mux.xHandler(), &mux);

    try server.start();
    defer server.stop();
    try startAdvertising(server);
    defer server.stopAdvertising();

    var restarted_after_disconnects: u32 = 0;
    var waited_ms: u32 = 0;
    while (waited_ms <= reconnect_timeout_ms) : (waited_ms += 1) {
        var disconnected_count: u32 = 0;
        state.mutex.lock();
        disconnected_count = state.disconnected_count;
        state.mutex.unlock();

        if (disconnected_count >= 2) break;
        if (disconnected_count > restarted_after_disconnects) {
            restarted_after_disconnects = disconnected_count;
            server.stopAdvertising();
            try startAdvertising(server);
        }
        lib.Thread.sleep(1 * 1_000_000);
    }
    if (waited_ms > reconnect_timeout_ms) return error.Timeout;

    var expected_write: [600]u8 = undefined;
    fillWritePayload(&expected_write);

    state.mutex.lock();
    defer state.mutex.unlock();
    try testing.expectEqual(@as(u32, 2), state.connected_count);
    try testing.expectEqual(@as(u32, 2), state.disconnected_count);
    try testing.expectEqual(@as(usize, 2), state.read_calls);
    try testing.expectEqual(@as(usize, 1), state.write_calls);
    try testing.expectEqual(@as(usize, 1), state.alpha_calls);
    try testing.expectEqual(@as(usize, 1), state.beta_calls);
    try testing.expectEqual(@as(?Chunk.Topic, topic_beta), state.last_topic);
    try testing.expect(lib.mem.eql(u8, state.write_value[0..state.write_len], &expected_write));
}

fn runPrimaryClientSession(comptime lib: type, conn: anytype, allocator: embed.mem.Allocator) !void {
    const testing = lib.testing;

    var expected_read: [600]u8 = undefined;
    fillReadPayload(&expected_read);

    var plain_char = try conn.characteristic(service_uuid, plain_char_uuid);
    var mux_char = try conn.characteristic(service_uuid, mux_char_uuid);
    try testing.expectEqual(negotiated_mtu, plain_char.attMtu());
    try testing.expectEqual(negotiated_mtu, mux_char.attMtu());

    const read_back = try plain_char.readX(allocator);
    defer allocator.free(read_back);
    try testing.expect(lib.mem.eql(u8, read_back, &expected_read));

    var write_value: [600]u8 = undefined;
    fillWritePayload(&write_value);
    try plain_char.writeX(&write_value);

    const alpha = try mux_char.get(topic_alpha, allocator);
    defer allocator.free(alpha);
    try testing.expect(lib.mem.eql(u8, alpha, "alpha"));

    const beta = try mux_char.get(topic_beta, allocator);
    defer allocator.free(beta);
    try testing.expect(lib.mem.eql(u8, beta, "beta"));

    try testing.expectError(error.AttError, mux_char.get(topic_missing, allocator));
}

fn runReconnectClientSession(comptime lib: type, conn: anytype, allocator: embed.mem.Allocator) !void {
    const testing = lib.testing;

    var expected_read: [600]u8 = undefined;
    fillReadPayload(&expected_read);

    var plain_char = try conn.characteristic(service_uuid, plain_char_uuid);
    try testing.expectEqual(negotiated_mtu, plain_char.attMtu());

    const read_back = try plain_char.readX(allocator);
    defer allocator.free(read_back);
    try testing.expect(lib.mem.eql(u8, read_back, &expected_read));
}

const FoundDevice = struct {
    addr: Central.BdAddr,
    addr_type: Central.AddrType,
};

fn discoverPeer(comptime lib: type, c: Central, state: anytype) !FoundDevice {
    resetFound(state);
    try c.startScanning(.{
        .active = true,
        .timeout_ms = timeout_ms,
        .service_uuids = &.{service_uuid},
    });
    defer c.stopScanning();
    return waitForFoundDevice(lib, state, timeout_ms);
}

fn resetFound(state: anytype) void {
    state.mutex.lock();
    defer state.mutex.unlock();
    state.found = false;
}

fn waitForFoundDevice(comptime lib: type, state: anytype, wait_ms: u32) !FoundDevice {
    var waited_ms: u32 = 0;
    while (waited_ms <= wait_ms) : (waited_ms += 1) {
        state.mutex.lock();
        const found = state.found;
        const addr = state.addr;
        const addr_type = state.addr_type;
        state.mutex.unlock();
        if (found) return .{ .addr = addr, .addr_type = addr_type };
        lib.Thread.sleep(1 * 1_000_000);
    }
    return error.Timeout;
}

fn waitForDisconnectCount(comptime lib: type, state: anytype, want: u32, wait_ms: u32) !void {
    var waited_ms: u32 = 0;
    while (waited_ms <= wait_ms) : (waited_ms += 1) {
        state.mutex.lock();
        const disconnected_count = state.disconnected_count;
        state.mutex.unlock();
        if (disconnected_count >= want) return;
        lib.Thread.sleep(1 * 1_000_000);
    }
    return error.Timeout;
}

fn startAdvertising(server: anytype) !void {
    try server.startAdvertising(.{
        .device_name = device_name,
        .service_uuids = &.{service_uuid},
    });
}

fn fillReadPayload(buf: []u8) void {
    for (buf, 0..) |*byte, i| {
        byte.* = @intCast(i % 251);
    }
}

fn fillWritePayload(buf: []u8) void {
    for (buf, 0..) |*byte, i| {
        byte.* = @intCast((i * 7) % 251);
    }
}

fn requireHostPointer(comptime T: type) void {
    if (@typeInfo(T) != .pointer) {
        @compileError("pair_xfer runner expects *Host instances");
    }
}

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
const testing_api = @import("testing");

const device_name = "PairXfer";
const service_uuid: u16 = 0x180D;
const plain_char_uuid: u16 = 0x2A57;
const xfer_char_uuid: u16 = 0x2A58;
/// Host-side mock: max wait for disconnect/sync during client flows (ms). Extra headroom for slow CI.
const timeout_ms: u32 = 15000;
/// Host-side mock: max wait for peripheral reconnect loop (ms).
const reconnect_timeout_ms: u32 = 30000;

pub fn makeCentral(comptime lib: type, comptime ClientType: type, host: anytype) testing_api.TestRunner {
    const HostPtr = @TypeOf(host);
    comptime requireHostPointer(HostPtr);

    const Runner = struct {
        host: HostPtr,

        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: embed.mem.Allocator) bool {
            runCentralRole(lib, ClientType, self.host, allocator) catch |err| {
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

pub fn makePeripheral(comptime lib: type, comptime ServerType: type, host: anytype) testing_api.TestRunner {
    const HostPtr = @TypeOf(host);
    comptime requireHostPointer(HostPtr);

    const Runner = struct {
        host: HostPtr,

        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: embed.mem.Allocator) bool {
            runPeripheralRole(lib, ServerType, self.host, allocator) catch |err| {
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

fn runCentralRole(comptime lib: type, comptime ClientType: type, host: anytype, allocator: embed.mem.Allocator) !void {
    const testing = lib.testing;

    const State = struct {
        mutex: lib.Thread.Mutex = .{},
        found: bool = false,
        addr: Central.BdAddr = .{0} ** 6,
        addr_type: Central.AddrType = .public,
        disconnected_count: u32 = 0,
    };

    const Hook = struct {
        fn cb(ctx: ?*anyopaque, evt: Central.Event) void {
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
    var client = ClientType.init(allocator);
    defer client.deinit();
    client.bind(host.central());
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

fn runPeripheralRole(comptime lib: type, comptime ServerType: type, host: anytype, allocator: embed.mem.Allocator) !void {
    const testing = lib.testing;
    const XferReadRequest = ServerType.XferReadRequest;
    const XferWriteRequest = ServerType.XferWriteRequest;
    var server = try ServerType.init(allocator);
    defer server.deinit();
    server.bind(host.peripheral());
    const peripheral = host.peripheral();

    const State = struct {
        mutex: lib.Thread.Mutex = .{},
        connected_count: u32 = 0,
        disconnected_count: u32 = 0,
        conn_handle: u16 = 0,
        read_calls: usize = 0,
        write_calls: usize = 0,
        xfer_read_calls: usize = 0,
        xfer_write_calls: usize = 0,
        xfer_alpha_value: [620]u8 = undefined,
        xfer_beta_value: [730]u8 = undefined,
        read_value: [32]u8 = [_]u8{0} ** 32,
        read_len: usize = 0,
        plain_write_value: [32]u8 = [_]u8{0} ** 32,
        plain_write_len: usize = 0,
        receiver_value: [384]u8 = undefined,
        receiver_len: usize = 0,

        fn init() @This() {
            var self = @This(){};
            self.read_len = fillPlainReadPayload(&self.read_value);
            fillServePayload(&self.xfer_alpha_value, 0x21);
            fillServePayload(&self.xfer_beta_value, 0x57);
            return self;
        }

        fn onEvent(ctx: ?*anyopaque, evt: Peripheral.Event) void {
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

        fn handlePlain(ctx: ?*anyopaque, req: *const Peripheral.Request, rw: *Peripheral.ResponseWriter) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.mutex.lock();
            defer self.mutex.unlock();
            switch (req.op) {
                .read => {
                    self.read_calls += 1;
                    rw.write(self.read_value[0..self.read_len]);
                },
                .write, .write_without_response => {
                    self.write_calls += 1;
                    self.plain_write_len = @min(self.plain_write_value.len, req.data.len);
                    @memcpy(self.plain_write_value[0..self.plain_write_len], req.data[0..self.plain_write_len]);
                },
            }
        }

        fn handleXferRead(ctx: ?*anyopaque, payload_allocator: embed.mem.Allocator, req: *const XferReadRequest) ![]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.mutex.lock();
            defer self.mutex.unlock();
            if (req.service_uuid != service_uuid) return error.UnexpectedServiceUuid;
            if (req.char_uuid != xfer_char_uuid) return error.UnexpectedCharUuid;

            const payload = switch (self.xfer_read_calls) {
                0 => self.xfer_alpha_value[0..],
                1 => self.xfer_beta_value[0..],
                else => self.xfer_beta_value[0..],
            };
            self.xfer_read_calls += 1;
            return payload_allocator.dupe(u8, payload);
        }

        fn handleXferWrite(ctx: ?*anyopaque, req: *const XferWriteRequest) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.mutex.lock();
            defer self.mutex.unlock();
            if (req.service_uuid != service_uuid or req.char_uuid != xfer_char_uuid) return;
            self.xfer_write_calls += 1;
            self.receiver_len = @min(self.receiver_value.len, req.data.len);
            @memcpy(self.receiver_value[0..self.receiver_len], req.data[0..self.receiver_len]);
        }
    };

    const chars = [_]bt.Peripheral.CharDef{
        bt.Peripheral.Char(plain_char_uuid, .{
            .read = true,
            .write = true,
            .write_without_response = true,
            .notify = true,
        }),
        bt.Peripheral.Char(xfer_char_uuid, .{
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

    server.setConfig(.{ .services = &services });
    try server.handle(service_uuid, plain_char_uuid, .{
        .onRequest = State.handlePlain,
    }, &state);
    try server.handleX(service_uuid, xfer_char_uuid, .{
        .onRead = State.handleXferRead,
        .onWrite = State.handleXferWrite,
    }, &state);

    try server.start();
    defer server.stop();
    try startAdvertising(&server);
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
            try startAdvertising(&server);
        }
        lib.Thread.sleep(1 * 1_000_000);
    }
    if (waited_ms > reconnect_timeout_ms) return error.Timeout;

    var expected_read: [32]u8 = undefined;
    const expected_read_len = fillPlainReadPayload(&expected_read);
    const expected_write = "plain-write";
    var expected_receiver: [384]u8 = undefined;
    fillReceiverPayload(&expected_receiver);

    state.mutex.lock();
    defer state.mutex.unlock();
    try testing.expectEqual(@as(u32, 2), state.connected_count);
    try testing.expectEqual(@as(u32, 2), state.disconnected_count);
    try testing.expectEqual(@as(usize, 2), state.read_calls);
    try testing.expectEqual(@as(usize, 1), state.write_calls);
    try testing.expectEqual(@as(usize, 2), state.xfer_read_calls);
    try testing.expectEqual(@as(usize, 1), state.xfer_write_calls);
    try testing.expect(lib.mem.eql(u8, state.read_value[0..state.read_len], expected_read[0..expected_read_len]));
    try testing.expect(lib.mem.eql(u8, state.plain_write_value[0..state.plain_write_len], expected_write));
    try testing.expect(lib.mem.eql(u8, state.receiver_value[0..state.receiver_len], &expected_receiver));
}

fn runPrimaryClientSession(comptime lib: type, conn: anytype, allocator: embed.mem.Allocator) !void {
    const testing = lib.testing;

    var expected_read: [32]u8 = undefined;
    const expected_read_len = fillPlainReadPayload(&expected_read);
    var expected_alpha: [620]u8 = undefined;
    var expected_beta: [730]u8 = undefined;
    fillServePayload(&expected_alpha, 0x21);
    fillServePayload(&expected_beta, 0x57);

    var plain_char = try conn.characteristic(service_uuid, plain_char_uuid);
    var xfer_char = try conn.characteristic(service_uuid, xfer_char_uuid);

    var plain_read_buf: [32]u8 = undefined;
    const plain_read_len = try plain_char.read(&plain_read_buf);
    try testing.expect(lib.mem.eql(u8, plain_read_buf[0..plain_read_len], expected_read[0..expected_read_len]));

    try plain_char.write("plain-write");

    var receiver_value: [384]u8 = undefined;
    fillReceiverPayload(&receiver_value);
    try xfer_char.writeX(&receiver_value);

    const alpha = try xfer_char.readX(allocator);
    defer allocator.free(alpha);
    try testing.expect(lib.mem.eql(u8, alpha, expected_alpha[0..]));

    const beta = try xfer_char.readX(allocator);
    defer allocator.free(beta);
    try testing.expect(lib.mem.eql(u8, beta, expected_beta[0..]));
}

fn runReconnectClientSession(comptime lib: type, conn: anytype, allocator: embed.mem.Allocator) !void {
    const testing = lib.testing;
    _ = allocator;

    var expected_read: [32]u8 = undefined;
    const expected_read_len = fillPlainReadPayload(&expected_read);

    var plain_char = try conn.characteristic(service_uuid, plain_char_uuid);

    var plain_read_buf: [32]u8 = undefined;
    const plain_read_len = try plain_char.read(&plain_read_buf);
    try testing.expect(lib.mem.eql(u8, plain_read_buf[0..plain_read_len], expected_read[0..expected_read_len]));
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

fn fillPlainReadPayload(buf: []u8) usize {
    const payload = "plain-read";
    @memcpy(buf[0..payload.len], payload);
    return payload.len;
}

fn fillReceiverPayload(buf: []u8) void {
    for (buf, 0..) |*byte, i| {
        byte.* = @intCast((i * 13 + 5) % 251);
    }
}

fn fillServePayload(buf: []u8, seed: u8) void {
    for (buf, 0..) |*byte, i| {
        byte.* = seed +% @as(u8, @truncate(i * 17));
    }
}

fn requireHostPointer(comptime T: type) void {
    if (@typeInfo(T) != .pointer) {
        @compileError("pair_xfer runner expects *Host instances");
    }
}

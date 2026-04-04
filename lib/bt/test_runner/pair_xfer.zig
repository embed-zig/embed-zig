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
const Chunk = @import("../host/xfer.zig").Chunk;
const xfer_serve_mux = @import("../host/server/ServeMux.zig");
const xfer_receiver = @import("../host/server/Receiver.zig");
const testing_api = @import("testing");

const device_name = "PairXfer";
const service_uuid: u16 = 0x180D;
const plain_char_uuid: u16 = 0x2A57;
const serve_mux_char_uuid: u16 = 0x2A58;
const receiver_char_uuid: u16 = 0x2A59;
const topic_alpha: Chunk.Topic = 0x0102030405060708;
const topic_beta: Chunk.Topic = 0x1112131415161718;
const topic_missing: Chunk.Topic = 0x2122232425262728;
const timeout_ms: u32 = 5000;
const reconnect_timeout_ms: u32 = 10000;

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
    const ServeMux = xfer_serve_mux.make(lib, ServerType);
    const Receiver = xfer_receiver.make(lib, ServerType);
    const ReceiverRequest = xfer_receiver.Request;
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
        serve_mux_alpha_calls: usize = 0,
        serve_mux_beta_calls: usize = 0,
        receiver_calls: usize = 0,
        last_serve_mux_topic: ?Chunk.Topic = null,
        alpha_metadata: [16]u8 = [_]u8{0} ** 16,
        alpha_metadata_len: usize = 0,
        beta_metadata: [16]u8 = [_]u8{0} ** 16,
        beta_metadata_len: usize = 0,
        serve_alpha_value: [620]u8 = undefined,
        serve_beta_value: [730]u8 = undefined,
        read_value: [32]u8 = [_]u8{0} ** 32,
        read_len: usize = 0,
        plain_write_value: [32]u8 = [_]u8{0} ** 32,
        plain_write_len: usize = 0,
        receiver_value: [384]u8 = undefined,
        receiver_len: usize = 0,

        fn init() @This() {
            var self = @This(){};
            self.read_len = fillPlainReadPayload(&self.read_value);
            fillServePayload(&self.serve_alpha_value, 0x21);
            fillServePayload(&self.serve_beta_value, 0x57);
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

        fn handleAlpha(ctx: ?*anyopaque, payload_allocator: embed.mem.Allocator, req: *const xfer_serve_mux.Request) ![]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.mutex.lock();
            defer self.mutex.unlock();
            self.serve_mux_alpha_calls += 1;
            self.last_serve_mux_topic = topic_alpha;
            self.alpha_metadata_len = @min(self.alpha_metadata.len, req.metadata.len);
            @memcpy(self.alpha_metadata[0..self.alpha_metadata_len], req.metadata[0..self.alpha_metadata_len]);
            return payload_allocator.dupe(u8, self.serve_alpha_value[0..]);
        }

        fn handleBeta(ctx: ?*anyopaque, payload_allocator: embed.mem.Allocator, req: *const xfer_serve_mux.Request) ![]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.mutex.lock();
            defer self.mutex.unlock();
            self.serve_mux_beta_calls += 1;
            self.last_serve_mux_topic = topic_beta;
            self.beta_metadata_len = @min(self.beta_metadata.len, req.metadata.len);
            @memcpy(self.beta_metadata[0..self.beta_metadata_len], req.metadata[0..self.beta_metadata_len]);
            return payload_allocator.dupe(u8, self.serve_beta_value[0..]);
        }

        fn handleReceiver(ctx: ?*anyopaque, req: *const ReceiverRequest) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.mutex.lock();
            defer self.mutex.unlock();
            self.receiver_calls += 1;
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
        bt.Peripheral.Char(serve_mux_char_uuid, .{
            .write = true,
            .write_without_response = true,
            .notify = true,
        }),
        bt.Peripheral.Char(receiver_char_uuid, .{
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

    var serve_mux = try ServeMux.init(allocator);
    defer serve_mux.deinit();
    var receiver = Receiver.init(allocator);
    defer receiver.deinit();

    server.setConfig(.{ .services = &services });
    try server.handle(service_uuid, plain_char_uuid, .{
        .onRequest = State.handlePlain,
    }, &state);
    try serve_mux.handle(topic_alpha, State.handleAlpha, &state);
    try serve_mux.handle(topic_beta, State.handleBeta, &state);
    try server.handle(service_uuid, serve_mux_char_uuid, serve_mux.handler(), &serve_mux);
    try receiver.handle(State.handleReceiver, &state);
    try server.handle(service_uuid, receiver_char_uuid, Receiver.handler(), &receiver);

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
    try testing.expectEqual(@as(usize, 1), state.serve_mux_alpha_calls);
    try testing.expectEqual(@as(usize, 1), state.serve_mux_beta_calls);
    try testing.expectEqual(@as(usize, 1), state.receiver_calls);
    try testing.expectEqual(@as(?Chunk.Topic, topic_beta), state.last_serve_mux_topic);
    try testing.expectEqual(@as(usize, 6), state.alpha_metadata_len);
    try testing.expect(lib.mem.eql(u8, state.alpha_metadata[0..state.alpha_metadata_len], "alpha?"));
    try testing.expectEqual(@as(usize, 5), state.beta_metadata_len);
    try testing.expect(lib.mem.eql(u8, state.beta_metadata[0..state.beta_metadata_len], "beta!"));
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
    var serve_mux_char = try conn.characteristic(service_uuid, serve_mux_char_uuid);
    var receiver_char = try conn.characteristic(service_uuid, receiver_char_uuid);

    var plain_read_buf: [32]u8 = undefined;
    const plain_read_len = try plain_char.read(&plain_read_buf);
    try testing.expect(lib.mem.eql(u8, plain_read_buf[0..plain_read_len], expected_read[0..expected_read_len]));

    try plain_char.write("plain-write");

    var receiver_value: [384]u8 = undefined;
    fillReceiverPayload(&receiver_value);
    try receiver_char.writeX(&receiver_value);

    const alpha = try serve_mux_char.readX(allocator, topic_alpha, "alpha?");
    defer allocator.free(alpha);
    try testing.expect(lib.mem.eql(u8, alpha, expected_alpha[0..]));

    const beta = try serve_mux_char.readX(allocator, topic_beta, "beta!");
    defer allocator.free(beta);
    try testing.expect(lib.mem.eql(u8, beta, expected_beta[0..]));

    try testing.expectError(error.AttError, serve_mux_char.readX(allocator, topic_missing, &.{}));
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

//! Pair test runner — exercises a Central and Peripheral as two peers.
//!
//! This runner models the real deployment shape:
//! - one side runs `runCentral`
//! - the other side runs `runPeripheral`
//!
//! On hardware these would run on two different boards/processes.
//! For local tests, a mock HCI system can run both in one process.

const stdz = @import("stdz");
const Central = @import("../Central.zig");
const Peripheral = @import("../Peripheral.zig");
const testing_api = @import("testing");

const device_name = "EmbedPair";
const service_uuid: u16 = 0xFFE0;
const char_uuid: u16 = 0xFFE1;
const initial_value = "72";
const write_value = "99";
const notify_request = "PAIR:NOTIFY";
const notify_value = "n1";
const indicate_request = "PAIR:INDICATE";
const indicate_value = "i1";
const pair_timeout_ms: u32 = 5000;

pub fn makeCentral(comptime lib: type, host: anytype) testing_api.TestRunner {
    const HostPtr = @TypeOf(host);
    comptime requireHostPointer(HostPtr);

    const Runner = struct {
        host: HostPtr,

        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: stdz.mem.Allocator) bool {
            _ = allocator;
            const c = self.host.central();
            c.start() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            defer c.stop();

            runCentralRole(lib, c) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: stdz.mem.Allocator) void {
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

        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: stdz.mem.Allocator) bool {
            _ = allocator;
            const p = self.host.peripheral();
            p.start() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            defer p.stop();

            runPeripheralRole(lib, p) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: stdz.mem.Allocator) void {
            _ = allocator;
            lib.testing.allocator.destroy(self);
        }
    };

    const runner = lib.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{ .host = host };
    return testing_api.TestRunner.make(Runner).new(runner);
}

fn runCentralRole(comptime lib: type, c: Central) !void {
    const testing = lib.testing;

    const State = struct {
        mutex: lib.Thread.Mutex = .{},
        found: bool = false,
        addr: Central.BdAddr = .{0} ** 6,
        addr_type: Central.AddrType = .public,
        conn_handle: u16 = 0,
        disconnected: bool = false,
        notification_count: u32 = 0,
        last_attr_handle: u16 = 0,
        last_notification: [64]u8 = undefined,
        last_notification_len: usize = 0,
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
                .connected => |info| {
                    state.conn_handle = info.conn_handle;
                    state.disconnected = false;
                },
                .disconnected => |_| {
                    state.disconnected = true;
                    state.conn_handle = 0;
                },
                .notification => |notif| {
                    state.notification_count += 1;
                    state.last_attr_handle = notif.attr_handle;
                    state.last_notification_len = @min(@as(usize, notif.len), state.last_notification.len);
                    if (state.last_notification_len > 0) {
                        @memcpy(
                            state.last_notification[0..state.last_notification_len],
                            notif.payload()[0..state.last_notification_len],
                        );
                    }
                },
            }
        }
    };

    var state = State{};
    c.addEventHook(@ptrCast(&state), Hook.cb);

    try testing.expectEqual(Central.State.idle, c.getState());
    try c.startScanning(.{
        .active = true,
        .timeout_ms = pair_timeout_ms,
        .service_uuids = &.{service_uuid},
    });

    const found = try waitForFoundDevice(lib, &state, pair_timeout_ms);
    c.stopScanning();

    _ = try c.connect(found.addr, found.addr_type, .{});
    const conn_handle = try waitForConnHandle(lib, &state, pair_timeout_ms);

    var services: [8]Central.DiscoveredService = undefined;
    const svc_count = try c.discoverServices(conn_handle, &services);
    const service = findService(services[0..svc_count], service_uuid) orelse return error.ServiceNotFound;

    var chars: [8]Central.DiscoveredChar = undefined;
    const char_count = try c.discoverChars(conn_handle, service.start_handle, service.end_handle, &chars);
    const ch = findChar(chars[0..char_count], char_uuid) orelse return error.CharacteristicNotFound;
    if (ch.cccd_handle == 0) return error.MissingCccd;

    var buf: [64]u8 = undefined;
    var n = try c.gattRead(conn_handle, ch.value_handle, &buf);
    try testing.expect(lib.mem.eql(u8, buf[0..n], initial_value));

    try c.gattWrite(conn_handle, ch.value_handle, write_value);
    n = try c.gattRead(conn_handle, ch.value_handle, &buf);
    try testing.expect(lib.mem.eql(u8, buf[0..n], write_value));

    try c.subscribe(conn_handle, ch.cccd_handle);
    try c.gattWrite(conn_handle, ch.value_handle, notify_request);
    try waitForNotification(lib, &state, 1, pair_timeout_ms);
    try expectLastNotification(lib, &state, ch.value_handle, notify_value);

    try c.gattWrite(conn_handle, ch.cccd_handle, &[_]u8{ 0x03, 0x00 });
    try c.gattWrite(conn_handle, ch.value_handle, indicate_request);
    try waitForNotification(lib, &state, 2, pair_timeout_ms);
    try expectLastNotification(lib, &state, ch.value_handle, indicate_value);

    try c.gattWrite(conn_handle, ch.cccd_handle, &[_]u8{ 0x00, 0x00 });
    c.disconnect(conn_handle);
    try waitForDisconnected(lib, &state, pair_timeout_ms);
}

fn runPeripheralRole(comptime lib: type, p: Peripheral) !void {
    const testing = lib.testing;

    const State = struct {
        mutex: lib.Thread.Mutex = .{},
        conn_handle: u16 = 0,
        connected: bool = false,
        disconnected: bool = false,
        pending_notify: bool = false,
        pending_indicate: bool = false,
        value: [64]u8 = undefined,
        value_len: usize = 0,
    };

    const Hook = struct {
        fn cb(ctx: ?*anyopaque, evt: Peripheral.Event) void {
            const state: *State = @ptrCast(@alignCast(ctx.?));
            state.mutex.lock();
            defer state.mutex.unlock();

            switch (evt) {
                .connected => |info| {
                    state.connected = true;
                    state.disconnected = false;
                    state.conn_handle = info.conn_handle;
                },
                .disconnected => |_| {
                    state.connected = false;
                    state.disconnected = true;
                    state.conn_handle = 0;
                },
                else => {},
            }
        }
    };

    const Handler = struct {
        fn serve(ctx: ?*anyopaque, req: *const Peripheral.Request, rw: *Peripheral.ResponseWriter) void {
            const state: *State = @ptrCast(@alignCast(ctx.?));
            state.mutex.lock();
            defer state.mutex.unlock();

            switch (req.op) {
                .read => {
                    rw.write(state.value[0..state.value_len]);
                },
                .write, .write_without_response => {
                    if (lib.mem.eql(u8, req.data, notify_request)) {
                        state.pending_notify = true;
                    } else if (lib.mem.eql(u8, req.data, indicate_request)) {
                        state.pending_indicate = true;
                    } else {
                        state.value_len = @min(req.data.len, state.value.len);
                        if (state.value_len > 0) {
                            @memcpy(state.value[0..state.value_len], req.data[0..state.value_len]);
                        }
                    }
                    rw.ok();
                },
            }
        }
    };

    var state = State{};
    state.value_len = @min(initial_value.len, state.value.len);
    if (state.value_len > 0) {
        @memcpy(state.value[0..state.value_len], initial_value[0..state.value_len]);
    }

    p.setConfig(.{
        .services = &.{
            Peripheral.Service(service_uuid, &.{
                Peripheral.Char(
                    char_uuid,
                    (Peripheral.CharConfig{}).withRead().withWrite().withWriteWithoutResponse().withNotify().withIndicate(),
                ),
            }),
        },
    });
    p.addEventHook(@ptrCast(&state), Hook.cb);
    p.setRequestHandler(&state, Handler.serve);
    try p.startAdvertising(.{
        .device_name = device_name,
        .service_uuids = &.{service_uuid},
    });

    try waitForPeripheralConnected(lib, &state, pair_timeout_ms);

    var waited_ms: u32 = 0;
    while (waited_ms <= pair_timeout_ms) : (waited_ms += 1) {
        var conn_handle: u16 = 0;
        var do_notify = false;
        var do_indicate = false;
        var disconnected = false;

        state.mutex.lock();
        if (state.pending_notify and state.conn_handle != 0) {
            state.pending_notify = false;
            conn_handle = state.conn_handle;
            do_notify = true;
        } else if (state.pending_indicate and state.conn_handle != 0) {
            state.pending_indicate = false;
            conn_handle = state.conn_handle;
            do_indicate = true;
        }
        disconnected = state.disconnected;
        state.mutex.unlock();

        if (do_notify) {
            p.notify(conn_handle, char_uuid, notify_value) catch |err| switch (err) {
                error.NotConnected => {
                    if (waitForDisconnectRace(lib, p, &state, conn_handle)) break;
                    return err;
                },
                else => return err,
            };
        }
        if (do_indicate) {
            p.indicate(conn_handle, char_uuid, indicate_value) catch |err| switch (err) {
                error.NotConnected => {
                    if (waitForDisconnectRace(lib, p, &state, conn_handle)) break;
                    return err;
                },
                else => return err,
            };
        }
        if (disconnected) break;

        lib.Thread.sleep(1 * 1_000_000);
    }

    try testing.expectEqual(Peripheral.State.idle, p.getState());
}

const FoundDevice = struct {
    addr: Central.BdAddr,
    addr_type: Central.AddrType,
};

fn waitForFoundDevice(comptime lib: type, state: anytype, timeout_ms: u32) !FoundDevice {
    const NS_PER_MS: u64 = 1_000_000;
    var waited_ms: u32 = 0;
    while (waited_ms <= timeout_ms) : (waited_ms += 1) {
        state.mutex.lock();
        const found = state.found;
        const addr = state.addr;
        const addr_type = state.addr_type;
        state.mutex.unlock();
        if (found) return .{ .addr = addr, .addr_type = addr_type };
        lib.Thread.sleep(NS_PER_MS);
    }
    return error.Timeout;
}

fn waitForConnHandle(comptime lib: type, state: anytype, timeout_ms: u32) !u16 {
    const NS_PER_MS: u64 = 1_000_000;
    var waited_ms: u32 = 0;
    while (waited_ms <= timeout_ms) : (waited_ms += 1) {
        state.mutex.lock();
        const conn_handle = state.conn_handle;
        state.mutex.unlock();
        if (conn_handle != 0) return conn_handle;
        lib.Thread.sleep(NS_PER_MS);
    }
    return error.Timeout;
}

fn waitForNotification(comptime lib: type, state: anytype, want_count: u32, timeout_ms: u32) !void {
    const NS_PER_MS: u64 = 1_000_000;
    var waited_ms: u32 = 0;
    while (waited_ms <= timeout_ms) : (waited_ms += 1) {
        state.mutex.lock();
        const count = state.notification_count;
        state.mutex.unlock();
        if (count >= want_count) return;
        lib.Thread.sleep(NS_PER_MS);
    }
    return error.Timeout;
}

fn expectLastNotification(comptime lib: type, state: anytype, attr_handle: u16, want: []const u8) !void {
    const testing = lib.testing;
    state.mutex.lock();
    defer state.mutex.unlock();
    try testing.expectEqual(attr_handle, state.last_attr_handle);
    try testing.expect(lib.mem.eql(u8, state.last_notification[0..state.last_notification_len], want));
}

fn waitForDisconnected(comptime lib: type, state: anytype, timeout_ms: u32) !void {
    const NS_PER_MS: u64 = 1_000_000;
    var waited_ms: u32 = 0;
    while (waited_ms <= timeout_ms) : (waited_ms += 1) {
        state.mutex.lock();
        const disconnected = state.disconnected;
        state.mutex.unlock();
        if (disconnected) return;
        lib.Thread.sleep(NS_PER_MS);
    }
    return error.Timeout;
}

fn waitForPeripheralConnected(comptime lib: type, state: anytype, timeout_ms: u32) !void {
    const NS_PER_MS: u64 = 1_000_000;
    var waited_ms: u32 = 0;
    while (waited_ms <= timeout_ms) : (waited_ms += 1) {
        state.mutex.lock();
        const connected = state.connected;
        state.mutex.unlock();
        if (connected) return;
        lib.Thread.sleep(NS_PER_MS);
    }
    return error.Timeout;
}

fn isDisconnectRace(state: anytype, conn_handle: u16) bool {
    state.mutex.lock();
    defer state.mutex.unlock();
    return state.disconnected or state.conn_handle == 0 or state.conn_handle != conn_handle;
}

fn waitForDisconnectRace(comptime lib: type, p: Peripheral, state: anytype, conn_handle: u16) bool {
    if (p.getState() != .connected or isDisconnectRace(state, conn_handle)) return true;

    var waited_ms: u32 = 0;
    while (waited_ms < 50) : (waited_ms += 1) {
        lib.Thread.sleep(1 * 1_000_000);
        if (p.getState() != .connected or isDisconnectRace(state, conn_handle)) return true;
    }
    return false;
}

fn findService(services: []const Central.DiscoveredService, uuid: u16) ?Central.DiscoveredService {
    for (services) |service| {
        if (service.uuid == uuid) return service;
    }
    return null;
}

fn findChar(chars: []const Central.DiscoveredChar, uuid: u16) ?Central.DiscoveredChar {
    for (chars) |ch| {
        if (ch.uuid == uuid) return ch;
    }
    return null;
}

fn requireHostPointer(comptime T: type) void {
    if (@typeInfo(T) != .pointer) {
        @compileError("pair runner expects *Host instances");
    }
}

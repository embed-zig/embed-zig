const embed = @import("embed");
const glib = @import("glib");
const gstd = @import("gstd");

pub const Modem = struct {
    const Driver = embed.drivers.Modem;

    mutex: gstd.runtime.sync.Mutex = .{},
    callback_ctx: ?*const anyopaque = null,
    callback_fn: ?Driver.CallbackFn = null,
    started: bool = false,
    data_state: Driver.DataState = .closed,
    packet_state: Driver.PacketState = .attached,
    apn_buf: [Driver.max_apn_len]u8 = [_]u8{0} ** Driver.max_apn_len,
    apn_len: usize = 0,
    read_deadline: ?glib.time.instant.Time = null,
    write_deadline: ?glib.time.instant.Time = null,

    const imei_value = "860000000000001";
    const imsi_value = "460001234567890";

    pub fn handle(self: *@This()) Driver {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn deinit(_: *@This()) void {}

    fn start(self: *@This()) Driver.StartError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.started = true;
    }

    fn stop(self: *@This()) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.started = false;
    }

    fn state(self: *@This()) Driver.State {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{
            .sim = .ready,
            .registration = .home,
            .packet = self.packet_state,
            .signal = .{
                .rssi_dbm = -73,
                .rat = .lte,
            },
        };
    }

    fn imei(_: *@This()) ?[]const u8 {
        return imei_value;
    }

    fn imsi(_: *@This()) ?[]const u8 {
        return imsi_value;
    }

    fn apn(self: *@This()) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.apn_len == 0) return null;
        return self.apn_buf[0..self.apn_len];
    }

    fn setApn(self: *@This(), value: []const u8) Driver.SetApnError!void {
        if (value.len > self.apn_buf.len) return error.InvalidConfig;

        var callback_ctx: ?*const anyopaque = null;
        var callback_fn: ?Driver.CallbackFn = null;
        self.mutex.lock();
        @memcpy(self.apn_buf[0..value.len], value);
        self.apn_len = value.len;
        callback_ctx = self.callback_ctx;
        callback_fn = self.callback_fn;
        self.mutex.unlock();

        if (callback_ctx) |ctx| {
            if (callback_fn) |emit_fn| emit_fn(ctx, 0, .{ .data = .{ .apn_changed = value } });
        }
    }

    fn dataOpen(self: *@This()) Driver.DataOpenError!void {
        self.setDataState(.open, .connected);
    }

    fn dataClose(self: *@This()) void {
        self.setDataState(.closed, .attached);
    }

    fn dataRead(_: *@This(), _: []u8) Driver.DataReadError!usize {
        return 0;
    }

    fn dataWrite(_: *@This(), buf: []const u8) Driver.DataWriteError!usize {
        return buf.len;
    }

    fn dataState(self: *@This()) Driver.DataState {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.data_state;
    }

    fn setDataReadDeadline(self: *@This(), deadline: ?glib.time.instant.Time) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.read_deadline = deadline;
    }

    fn setDataWriteDeadline(self: *@This(), deadline: ?glib.time.instant.Time) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.write_deadline = deadline;
    }

    fn setEventCallback(self: *@This(), ctx: *const anyopaque, emit_fn: Driver.CallbackFn) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.callback_ctx = ctx;
        self.callback_fn = emit_fn;
    }

    fn clearEventCallback(self: *@This()) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.callback_ctx = null;
        self.callback_fn = null;
    }

    fn setDataState(self: *@This(), data_state_value: Driver.DataState, packet_state_value: Driver.PacketState) void {
        var callback_ctx: ?*const anyopaque = null;
        var callback_fn: ?Driver.CallbackFn = null;
        self.mutex.lock();
        self.data_state = data_state_value;
        self.packet_state = packet_state_value;
        callback_ctx = self.callback_ctx;
        callback_fn = self.callback_fn;
        self.mutex.unlock();

        if (callback_ctx) |ctx| {
            if (callback_fn) |emit_fn| emit_fn(ctx, 0, .{ .data = .{ .packet_state_changed = packet_state_value } });
        }
    }

    fn fromPtr(ptr: *anyopaque) *@This() {
        return @ptrCast(@alignCast(ptr));
    }

    fn deinitFn(ptr: *anyopaque) void {
        fromPtr(ptr).deinit();
    }

    fn startFn(ptr: *anyopaque) Driver.StartError!void {
        return fromPtr(ptr).start();
    }

    fn stopFn(ptr: *anyopaque) void {
        fromPtr(ptr).stop();
    }

    fn stateFn(ptr: *anyopaque) Driver.State {
        return fromPtr(ptr).state();
    }

    fn imeiFn(ptr: *anyopaque) ?[]const u8 {
        return fromPtr(ptr).imei();
    }

    fn imsiFn(ptr: *anyopaque) ?[]const u8 {
        return fromPtr(ptr).imsi();
    }

    fn apnFn(ptr: *anyopaque) ?[]const u8 {
        return fromPtr(ptr).apn();
    }

    fn setApnFn(ptr: *anyopaque, value: []const u8) Driver.SetApnError!void {
        return fromPtr(ptr).setApn(value);
    }

    fn dataOpenFn(ptr: *anyopaque) Driver.DataOpenError!void {
        return fromPtr(ptr).dataOpen();
    }

    fn dataCloseFn(ptr: *anyopaque) void {
        fromPtr(ptr).dataClose();
    }

    fn dataReadFn(ptr: *anyopaque, buf: []u8) Driver.DataReadError!usize {
        return fromPtr(ptr).dataRead(buf);
    }

    fn dataWriteFn(ptr: *anyopaque, buf: []const u8) Driver.DataWriteError!usize {
        return fromPtr(ptr).dataWrite(buf);
    }

    fn dataStateFn(ptr: *anyopaque) Driver.DataState {
        return fromPtr(ptr).dataState();
    }

    fn setDataReadDeadlineFn(ptr: *anyopaque, deadline: ?glib.time.instant.Time) void {
        fromPtr(ptr).setDataReadDeadline(deadline);
    }

    fn setDataWriteDeadlineFn(ptr: *anyopaque, deadline: ?glib.time.instant.Time) void {
        fromPtr(ptr).setDataWriteDeadline(deadline);
    }

    fn setEventCallbackFn(ptr: *anyopaque, ctx: *const anyopaque, emit_fn: Driver.CallbackFn) void {
        fromPtr(ptr).setEventCallback(ctx, emit_fn);
    }

    fn clearEventCallbackFn(ptr: *anyopaque) void {
        fromPtr(ptr).clearEventCallback();
    }

    const vtable = Driver.VTable{
        .deinit = deinitFn,
        .start = startFn,
        .stop = stopFn,
        .state = stateFn,
        .imei = imeiFn,
        .imsi = imsiFn,
        .apn = apnFn,
        .setApn = setApnFn,
        .dataOpen = dataOpenFn,
        .dataClose = dataCloseFn,
        .dataRead = dataReadFn,
        .dataWrite = dataWriteFn,
        .dataState = dataStateFn,
        .setDataReadDeadline = setDataReadDeadlineFn,
        .setDataWriteDeadline = setDataWriteDeadlineFn,
        .setEventCallback = setEventCallbackFn,
        .clearEventCallback = clearEventCallbackFn,
    };
};

pub fn TestRunner(comptime std: type) glib.testing.TestRunner {
    const testing_api = glib.testing;
    const Driver = embed.drivers.Modem;

    const Runner = struct {
        pub fn init(self: *@This(), allocator: std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            var modem = Modem{};
            const handle = modem.handle();
            var callback_count: usize = 0;
            const callback = struct {
                fn emitFn(ctx: *const anyopaque, _: u32, event: Driver.Event) void {
                    const count: *usize = @ptrCast(@alignCast(@constCast(ctx)));
                    switch (event) {
                        .data => count.* += 1,
                        else => {},
                    }
                }
            }.emitFn;

            handle.start() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            std.testing.expect(modem.started) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            handle.setEventCallback(&callback_count, callback);
            handle.setApn("internet") catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            std.testing.expectEqualStrings("internet", handle.apn().?) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            handle.dataOpen() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            std.testing.expectEqual(Driver.DataState.open, handle.dataState()) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            std.testing.expectEqual(Driver.PacketState.connected, handle.state().packet) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            handle.dataClose();
            std.testing.expectEqual(Driver.DataState.closed, handle.dataState()) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            std.testing.expect(callback_count >= 3) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            handle.clearEventCallback();
            handle.stop();
            std.testing.expect(!modem.started) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}

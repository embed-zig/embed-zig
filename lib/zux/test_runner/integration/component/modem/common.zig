const modem_api = @import("modem");

const Assembler = @import("../../../../Assembler.zig");

pub const component_modem = @import("../../../../component/modem.zig");

pub fn makeBuiltApp(comptime lib: type, comptime Channel: fn (type) type) type {
    comptime {
        @setEvalBranchQuota(20_000);
    }

    const AssemblerType = Assembler.make(lib, .{
        .pipeline = .{
            .tick_interval_ns = lib.time.ns_per_ms,
        },
    }, Channel);
    var assembler = AssemblerType.init();
    assembler.addModem(.cell, 51);
    assembler.setState("net/modem", .{.cell});

    const BuildConfig = assembler.BuildConfig();
    const build_config: BuildConfig = .{
        .cell = modem_api.Modem,
    };
    return assembler.build(build_config);
}

pub const DummyModemImpl = struct {
    receiver_ctx: ?*const anyopaque = null,
    emit_fn: ?component_modem.CallbackFn = null,

    pub fn deinit(_: *@This()) void {}

    pub fn state(_: *@This()) modem_api.Modem.State {
        return .{
            .sim = .unknown,
            .registration = .offline,
            .packet = .detached,
            .signal = null,
        };
    }

    pub fn imei(_: *@This()) ?[]const u8 {
        return "860000000000001";
    }

    pub fn imsi(_: *@This()) ?[]const u8 {
        return "460001234567890";
    }

    pub fn apn(_: *@This()) ?[]const u8 {
        return "bootstrap";
    }

    pub fn setApn(_: *@This(), _: []const u8) modem_api.Modem.SetApnError!void {}

    pub fn setEventCallback(self: *@This(), ctx: *const anyopaque, emit_fn: component_modem.CallbackFn) void {
        self.receiver_ctx = ctx;
        self.emit_fn = emit_fn;
    }

    pub fn clearEventCallback(self: *@This()) void {
        self.receiver_ctx = null;
        self.emit_fn = null;
    }

    pub fn emit(self: *@This(), source_id: u32, event: modem_api.Modem.Event) !void {
        const receiver_ctx = self.receiver_ctx orelse return error.MissingReceiver;
        const emit_fn = self.emit_fn orelse return error.MissingHook;
        emit_fn(receiver_ctx, source_id, event);
    }
};

pub fn makeAdapter(dummy: *DummyModemImpl) modem_api.Modem {
    return .{
        .ptr = @ptrCast(dummy),
        .vtable = &adapter_vtable,
    };
}

pub fn signal(rssi_dbm: i16, ber: ?u8, rat: modem_api.Modem.Rat) modem_api.Modem.SignalInfo {
    return .{
        .rssi_dbm = rssi_dbm,
        .ber = ber,
        .rat = rat,
    };
}

const adapter_vtable = modem_api.Modem.VTable{
    .deinit = struct {
        fn call(ptr: *anyopaque) void {
            const self: *DummyModemImpl = @ptrCast(@alignCast(ptr));
            self.deinit();
        }
    }.call,
    .state = struct {
        fn call(ptr: *anyopaque) modem_api.Modem.State {
            const self: *DummyModemImpl = @ptrCast(@alignCast(ptr));
            return self.state();
        }
    }.call,
    .imei = struct {
        fn call(ptr: *anyopaque) ?[]const u8 {
            const self: *DummyModemImpl = @ptrCast(@alignCast(ptr));
            return self.imei();
        }
    }.call,
    .imsi = struct {
        fn call(ptr: *anyopaque) ?[]const u8 {
            const self: *DummyModemImpl = @ptrCast(@alignCast(ptr));
            return self.imsi();
        }
    }.call,
    .apn = struct {
        fn call(ptr: *anyopaque) ?[]const u8 {
            const self: *DummyModemImpl = @ptrCast(@alignCast(ptr));
            return self.apn();
        }
    }.call,
    .setApn = struct {
        fn call(ptr: *anyopaque, value: []const u8) modem_api.Modem.SetApnError!void {
            const self: *DummyModemImpl = @ptrCast(@alignCast(ptr));
            return self.setApn(value);
        }
    }.call,
    .setEventCallback = struct {
        fn call(ptr: *anyopaque, ctx: *const anyopaque, emit_fn: component_modem.CallbackFn) void {
            const self: *DummyModemImpl = @ptrCast(@alignCast(ptr));
            self.setEventCallback(ctx, emit_fn);
        }
    }.call,
    .clearEventCallback = struct {
        fn call(ptr: *anyopaque) void {
            const self: *DummyModemImpl = @ptrCast(@alignCast(ptr));
            self.clearEventCallback();
        }
    }.call,
};

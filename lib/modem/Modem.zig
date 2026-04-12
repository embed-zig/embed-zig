//! modem.Modem — type-erased modem adapter bundle.

const testing_api = @import("testing");

const root = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const max_apn_len: usize = 32;
pub const max_phone_number_len: usize = 32;
pub const max_sms_text_len: usize = 256;

pub const Rat = enum {
    unknown,
    gsm,
    gprs,
    edge,
    wcdma,
    hspa,
    lte,
    lte_m,
    nb_iot,
    nr5g,
};

pub const SimState = enum {
    unknown,
    absent,
    locked,
    ready,
};

pub const RegistrationState = enum {
    offline,
    searching,
    denied,
    home,
    roaming,
};

pub const PacketState = enum {
    detached,
    attaching,
    attached,
    connecting,
    connected,
};

pub const SignalInfo = struct {
    rssi_dbm: i16 = 0,
    ber: ?u8 = null,
    rat: Rat = .unknown,
};

pub const CallDirection = enum {
    incoming,
    outgoing,
};

pub const CallState = enum {
    incoming,
    dialing,
    alerting,
    active,
    held,
    waiting,
};

pub const CallEndReason = enum {
    unknown,
    local_hangup,
    remote_hangup,
    missed,
    rejected,
    busy,
    failed,
};

pub const CallInfo = struct {
    call_id: u8 = 0,
    direction: CallDirection = .incoming,
    number: ?[]const u8 = null,
};

pub const CallStatus = struct {
    call_id: u8 = 0,
    direction: CallDirection = .incoming,
    state: CallState,
    number: ?[]const u8 = null,
};

pub const CallEndInfo = struct {
    call_id: u8 = 0,
    reason: CallEndReason = .unknown,
};

pub const SmsStorage = enum {
    unknown,
    sim,
    modem,
};

pub const SmsEncoding = enum {
    gsm7,
    utf8,
    ucs2,
    binary,
};

pub const SmsMessage = struct {
    index: ?u16 = null,
    storage: SmsStorage = .unknown,
    sender: ?[]const u8 = null,
    text: []const u8,
    encoding: SmsEncoding = .utf8,
};

pub const GnssState = enum {
    idle,
    acquiring,
    fixed,
};

pub const GnssFixQuality = enum {
    none,
    two_d,
    three_d,
};

pub const GnssFix = struct {
    quality: GnssFixQuality = .none,
    latitude_deg: f64 = 0,
    longitude_deg: f64 = 0,
    altitude_m: ?f32 = null,
    speed_mps: ?f32 = null,
    course_deg: ?f32 = null,
    hdop: ?f32 = null,
    satellites_in_view: u8 = 0,
    satellites_used: u8 = 0,
    timestamp_ms: ?u64 = null,
};

pub const State = struct {
    sim: SimState = .unknown,
    registration: RegistrationState = .offline,
    packet: PacketState = .detached,
    signal: ?SignalInfo = null,
};

pub const SimEvent = union(enum) {
    state_changed: SimState,
};

pub const NetworkEvent = union(enum) {
    registration_changed: RegistrationState,
    signal_changed: SignalInfo,
};

pub const DataEvent = union(enum) {
    packet_state_changed: PacketState,
    apn_changed: []const u8,
};

pub const CallEvent = union(enum) {
    incoming: CallInfo,
    state_changed: CallStatus,
    ended: CallEndInfo,
};

pub const SmsEvent = union(enum) {
    received: SmsMessage,
};

pub const GnssEvent = union(enum) {
    state_changed: GnssState,
    fix_changed: GnssFix,
};

pub const Event = union(enum) {
    sim: SimEvent,
    network: NetworkEvent,
    data: DataEvent,
    call: CallEvent,
    sms: SmsEvent,
    gnss: GnssEvent,
};

pub const SetApnError = error{
    InvalidConfig,
    Busy,
    Unexpected,
};

pub const CallbackFn = *const fn (ctx: *const anyopaque, source_id: u32, event: Event) void;

pub const VTable = struct {
    deinit: *const fn (ptr: *anyopaque) void,
    state: *const fn (ptr: *anyopaque) State,
    imei: *const fn (ptr: *anyopaque) ?[]const u8,
    imsi: *const fn (ptr: *anyopaque) ?[]const u8,
    apn: *const fn (ptr: *anyopaque) ?[]const u8,
    setApn: *const fn (ptr: *anyopaque, apn: []const u8) SetApnError!void,
    setEventCallback: *const fn (ptr: *anyopaque, ctx: *const anyopaque, emit_fn: CallbackFn) void,
    clearEventCallback: *const fn (ptr: *anyopaque) void,
};

pub fn deinit(self: root) void {
    self.vtable.deinit(self.ptr);
}

pub fn state(self: root) State {
    return self.vtable.state(self.ptr);
}

pub fn imei(self: root) ?[]const u8 {
    return self.vtable.imei(self.ptr);
}

pub fn imsi(self: root) ?[]const u8 {
    return self.vtable.imsi(self.ptr);
}

pub fn apn(self: root) ?[]const u8 {
    return self.vtable.apn(self.ptr);
}

pub fn setApn(self: root, value: []const u8) SetApnError!void {
    return self.vtable.setApn(self.ptr, value);
}

pub fn setEventCallback(self: root, ctx: *const anyopaque, emit_fn: CallbackFn) void {
    self.vtable.setEventCallback(self.ptr, ctx, emit_fn);
}

pub fn clearEventCallback(self: root) void {
    self.vtable.clearEventCallback(self.ptr);
}

pub fn make(comptime lib: type, comptime Impl: type) type {
    comptime {
        if (!@hasDecl(Impl, "Config")) @compileError("Modem impl must define Config");
        if (!@hasDecl(Impl, "init")) @compileError("Modem impl must define init");
        if (!@hasDecl(Impl, "deinit")) @compileError("Modem impl must define deinit");
        if (!@hasDecl(Impl, "state")) @compileError("Modem impl must define state");
        if (!@hasDecl(Impl, "imei")) @compileError("Modem impl must define imei");
        if (!@hasDecl(Impl, "imsi")) @compileError("Modem impl must define imsi");
        if (!@hasDecl(Impl, "apn")) @compileError("Modem impl must define apn");
        if (!@hasDecl(Impl, "setApn")) @compileError("Modem impl must define setApn");
        if (!@hasDecl(Impl, "setEventCallback")) @compileError("Modem impl must define setEventCallback");
        if (!@hasDecl(Impl, "clearEventCallback")) @compileError("Modem impl must define clearEventCallback");
        if (!@hasField(Impl.Config, "allocator")) @compileError("Modem impl Config must define allocator");

        _ = @as(*const fn (Impl.Config) anyerror!Impl, &Impl.init);
        _ = @as(*const fn (*Impl) void, &Impl.deinit);
        _ = @as(*const fn (*Impl) State, &Impl.state);
        _ = @as(*const fn (*Impl) ?[]const u8, &Impl.imei);
        _ = @as(*const fn (*Impl) ?[]const u8, &Impl.imsi);
        _ = @as(*const fn (*Impl) ?[]const u8, &Impl.apn);
        _ = @as(*const fn (*Impl, []const u8) SetApnError!void, &Impl.setApn);
        _ = @as(*const fn (*Impl, *const anyopaque, CallbackFn) void, &Impl.setEventCallback);
        _ = @as(*const fn (*Impl) void, &Impl.clearEventCallback);
    }

    const Allocator = lib.mem.Allocator;
    const Ctx = struct {
        allocator: Allocator,
        impl: Impl,

        pub fn deinit(self: *@This()) void {
            self.impl.deinit();
            self.allocator.destroy(self);
        }

        pub fn state(self: *@This()) State {
            return self.impl.state();
        }

        pub fn imei(self: *@This()) ?[]const u8 {
            return self.impl.imei();
        }

        pub fn imsi(self: *@This()) ?[]const u8 {
            return self.impl.imsi();
        }

        pub fn apn(self: *@This()) ?[]const u8 {
            return self.impl.apn();
        }

        pub fn setApn(self: *@This(), value: []const u8) SetApnError!void {
            return self.impl.setApn(value);
        }

        pub fn setEventCallback(self: *@This(), ctx: *const anyopaque, emit_fn: CallbackFn) void {
            self.impl.setEventCallback(ctx, emit_fn);
        }

        pub fn clearEventCallback(self: *@This()) void {
            self.impl.clearEventCallback();
        }
    };
    const VTableGen = struct {
        fn deinitFn(ptr: *anyopaque) void {
            const self: *Ctx = @ptrCast(@alignCast(ptr));
            self.deinit();
        }

        fn stateFn(ptr: *anyopaque) State {
            const self: *Ctx = @ptrCast(@alignCast(ptr));
            return self.state();
        }

        fn imeiFn(ptr: *anyopaque) ?[]const u8 {
            const self: *Ctx = @ptrCast(@alignCast(ptr));
            return self.imei();
        }

        fn imsiFn(ptr: *anyopaque) ?[]const u8 {
            const self: *Ctx = @ptrCast(@alignCast(ptr));
            return self.imsi();
        }

        fn apnFn(ptr: *anyopaque) ?[]const u8 {
            const self: *Ctx = @ptrCast(@alignCast(ptr));
            return self.apn();
        }

        fn setApnFn(ptr: *anyopaque, value: []const u8) SetApnError!void {
            const self: *Ctx = @ptrCast(@alignCast(ptr));
            return self.setApn(value);
        }

        fn setEventCallbackFn(ptr: *anyopaque, ctx: *const anyopaque, emit_fn: CallbackFn) void {
            const self: *Ctx = @ptrCast(@alignCast(ptr));
            self.setEventCallback(ctx, emit_fn);
        }

        fn clearEventCallbackFn(ptr: *anyopaque) void {
            const self: *Ctx = @ptrCast(@alignCast(ptr));
            self.clearEventCallback();
        }

        const vtable = VTable{
            .deinit = deinitFn,
            .state = stateFn,
            .imei = imeiFn,
            .imsi = imsiFn,
            .apn = apnFn,
            .setApn = setApnFn,
            .setEventCallback = setEventCallbackFn,
            .clearEventCallback = clearEventCallbackFn,
        };
    };

    return struct {
        pub const Config = Impl.Config;

        pub fn init(config: Config) !root {
            var impl = try Impl.init(config);
            errdefer impl.deinit();

            const storage = try config.allocator.create(Ctx);
            errdefer config.allocator.destroy(storage);
            storage.* = .{
                .allocator = config.allocator,
                .impl = impl,
            };
            return .{
                .ptr = storage,
                .vtable = &VTableGen.vtable,
            };
        }
    };
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const TestCase = struct {
        fn exposesVtableSurface() !void {
            const Impl = struct {
                pub const Config = struct {
                    allocator: lib.mem.Allocator,
                };

                imei_value: []const u8 = "860000000000001",
                imsi_value: []const u8 = "460001234567890",
                apn_value: []const u8 = "internet",

                pub fn init(config: Config) !@This() {
                    _ = config;
                    return .{};
                }

                pub fn deinit(self: *@This()) void {
                    _ = self;
                }

                pub fn state(_: *@This()) State {
                    return .{
                        .sim = .ready,
                        .registration = .home,
                        .packet = .attached,
                        .signal = .{
                            .rssi_dbm = -73,
                            .rat = .lte,
                        },
                    };
                }

                pub fn imei(self: *@This()) ?[]const u8 {
                    return self.imei_value;
                }

                pub fn imsi(self: *@This()) ?[]const u8 {
                    return self.imsi_value;
                }

                pub fn apn(self: *@This()) ?[]const u8 {
                    return self.apn_value;
                }

                pub fn setApn(self: *@This(), value: []const u8) SetApnError!void {
                    self.apn_value = value;
                }

                pub fn setEventCallback(self: *@This(), ctx: *const anyopaque, emit_fn: CallbackFn) void {
                    _ = self;
                    _ = ctx;
                    _ = emit_fn;
                }

                pub fn clearEventCallback(self: *@This()) void {
                    _ = self;
                }
            };

            comptime {
                _ = root.deinit;
                _ = root.state;
                _ = root.imei;
                _ = root.imsi;
                _ = root.apn;
                _ = root.setApn;
                _ = root.setEventCallback;
                _ = root.clearEventCallback;
                _ = root.Rat;
                _ = root.SimState;
                _ = root.RegistrationState;
                _ = root.PacketState;
                _ = root.SignalInfo;
                _ = root.CallDirection;
                _ = root.CallState;
                _ = root.CallEndReason;
                _ = root.CallInfo;
                _ = root.CallStatus;
                _ = root.CallEndInfo;
                _ = root.SmsStorage;
                _ = root.SmsEncoding;
                _ = root.SmsMessage;
                _ = root.GnssState;
                _ = root.GnssFixQuality;
                _ = root.GnssFix;
                _ = root.State;
                _ = root.SimEvent;
                _ = root.NetworkEvent;
                _ = root.DataEvent;
                _ = root.CallEvent;
                _ = root.SmsEvent;
                _ = root.GnssEvent;
                _ = root.Event;
                _ = root.SetApnError;
                _ = root.CallbackFn;
                _ = root.make;
                _ = make(lib, Impl).init;
                if (!@hasField(make(lib, Impl).Config, "allocator")) {
                    @compileError("make config must expose allocator");
                }
            }
        }

        fn forwardsIdentityAndApnSurface(allocator: lib.mem.Allocator) !void {
            const Impl = struct {
                pub const Config = struct {
                    allocator: lib.mem.Allocator,
                };

                imei_value: []const u8 = "860000000000001",
                imsi_value: []const u8 = "460001234567890",
                apn_buf: [max_apn_len]u8 = [_]u8{0} ** max_apn_len,
                apn_len: usize = "internet".len,

                const Self = @This();

                pub fn init(config: Config) !Self {
                    _ = config;
                    var self = Self{};
                    @memcpy(self.apn_buf[0.."internet".len], "internet");
                    self.apn_len = "internet".len;
                    return self;
                }

                pub fn deinit(self: *Self) void {
                    _ = self;
                }

                pub fn state(_: *Self) State {
                    return .{
                        .sim = .ready,
                        .registration = .home,
                        .packet = .connected,
                        .signal = .{
                            .rssi_dbm = -68,
                            .ber = 1,
                            .rat = .lte,
                        },
                    };
                }

                pub fn imei(self: *Self) ?[]const u8 {
                    return self.imei_value;
                }

                pub fn imsi(self: *Self) ?[]const u8 {
                    return self.imsi_value;
                }

                pub fn apn(self: *Self) ?[]const u8 {
                    return self.apn_buf[0..self.apn_len];
                }

                pub fn setApn(self: *Self, value: []const u8) SetApnError!void {
                    if (value.len == 0 or value.len > self.apn_buf.len) return error.InvalidConfig;
                    @memset(self.apn_buf[0..], 0);
                    @memcpy(self.apn_buf[0..value.len], value);
                    self.apn_len = value.len;
                }

                pub fn setEventCallback(self: *Self, ctx: *const anyopaque, emit_fn: CallbackFn) void {
                    _ = self;
                    _ = ctx;
                    _ = emit_fn;
                }

                pub fn clearEventCallback(self: *Self) void {
                    _ = self;
                }
            };

            const Built = make(lib, Impl);
            var modem = try Built.init(.{ .allocator = allocator });
            defer modem.deinit();

            const current_state = modem.state();
            try lib.testing.expectEqual(SimState.ready, current_state.sim);
            try lib.testing.expectEqual(RegistrationState.home, current_state.registration);
            try lib.testing.expectEqual(PacketState.connected, current_state.packet);
            try lib.testing.expectEqual(@as(?[]const u8, "860000000000001"), modem.imei());
            try lib.testing.expectEqual(@as(?[]const u8, "460001234567890"), modem.imsi());
            try lib.testing.expectEqualStrings("internet", modem.apn().?);

            try modem.setApn("cmnet");
            try lib.testing.expectEqualStrings("cmnet", modem.apn().?);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;

            TestCase.exposesVtableSurface() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.forwardsIdentityAndApnSurface(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}

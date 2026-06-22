const glib = @import("glib");

const consts = @import("../consts.zig");

pub const source_id: u32 = 1;

pub const ActionEvent = struct {
    pub const event_name = "ble_speed_test.action";

    allocator: glib.std.mem.Allocator,
    action: Action,
    role: consts.Role = .server,
    conn_handle: u16 = 0,
    conn_interval: u16 = 0,
    att_mtu: u16 = consts.default_att_mtu,
    error_code: u32 = 0,
    error_name_len: u8 = 0,
    error_name_buf: [32]u8 = [_]u8{0} ** 32,

    pub const Action = enum(u8) {
        ready,
        start,
        stop,
        reset,
        fail,
    };

    pub fn init(allocator: glib.std.mem.Allocator, action: Action) !*@This() {
        const payload = try allocator.create(@This());
        payload.* = .{
            .allocator = allocator,
            .action = action,
        };
        return payload;
    }

    pub fn decodeJson(allocator: glib.std.mem.Allocator, value: glib.std.json.Value) !*@This() {
        const payload = try allocator.create(@This());
        errdefer allocator.destroy(payload);
        payload.* = .{
            .allocator = allocator,
            .action = try actionField(value, "action"),
            .role = roleFieldDefault(value, "role", .server),
            .conn_handle = u16FieldDefault(value, "conn_handle", 0),
            .conn_interval = u16FieldDefault(value, "conn_interval", 0),
            .att_mtu = u16FieldDefault(value, "att_mtu", consts.default_att_mtu),
            .error_code = u32FieldDefault(value, "error_code", u32FieldDefault(value, "code", 0)),
        };
        if (stringField(value, "error_name")) |name| {
            copyText(&payload.error_name_buf, &payload.error_name_len, name);
        } else |_| {}
        return payload;
    }

    pub fn deinit(self: *@This()) void {
        self.allocator.destroy(self);
    }
};

pub const StatsDeltaEvent = struct {
    pub const event_name = "ble_speed_test.stats_delta";

    allocator: glib.std.mem.Allocator,
    window_ms: u32 = consts.default_window_ms,
    tx_bytes: u32 = 0,
    rx_bytes: u32 = 0,
    tx_packets: u32 = 0,
    rx_packets: u32 = 0,
    rx_expected_seq: u32 = 0,
    rx_lost_packets: u32 = 0,
    rx_reordered_packets: u32 = 0,

    pub fn init(allocator: glib.std.mem.Allocator) !*@This() {
        const payload = try allocator.create(@This());
        payload.* = .{ .allocator = allocator };
        return payload;
    }

    pub fn decodeJson(allocator: glib.std.mem.Allocator, value: glib.std.json.Value) !*@This() {
        const payload = try allocator.create(@This());
        errdefer allocator.destroy(payload);
        payload.* = .{
            .allocator = allocator,
            .window_ms = u32FieldDefault(value, "window_ms", consts.default_window_ms),
            .tx_bytes = u32FieldDefault(value, "tx_bytes", 0),
            .rx_bytes = u32FieldDefault(value, "rx_bytes", 0),
            .tx_packets = u32FieldDefault(value, "tx_packets", 0),
            .rx_packets = u32FieldDefault(value, "rx_packets", 0),
            .rx_expected_seq = u32FieldDefault(value, "rx_expected_seq", 0),
            .rx_lost_packets = u32FieldDefault(value, "rx_lost_packets", 0),
            .rx_reordered_packets = u32FieldDefault(value, "rx_reordered_packets", 0),
        };
        return payload;
    }

    pub fn deinit(self: *@This()) void {
        self.allocator.destroy(self);
    }
};

pub fn registerCustomEvents(assembler: anytype) void {
    assembler.registerCustomEvent(ActionEvent);
    assembler.registerCustomEvent(StatsDeltaEvent);
}

pub fn initState(comptime State: type, role: consts.Role) State {
    var state: State = .{
        .role = switch (role) {
            .client => .client,
            .server => .server,
        },
        .phase = switch (role) {
            .client => .scanning,
            .server => .advertising,
        },
        .connected = false,
        .subscribed = false,
        .conn_handle = 0,
        .conn_interval = 0,
        .att_mtu = consts.default_att_mtu,
        .payload_len = consts.default_payload_len,
        .service_uuid = consts.service_uuid,
        .tx_char_uuid = consts.tx_char_uuid,
        .rx_char_uuid = consts.rx_char_uuid,
        .last_error_code = 0,
        .last_error_name_len = 0,
        .last_error_name_buf = [_]u8{0} ** 32,
        .running = false,
        .window_ms = consts.default_window_ms,
        .tx_seq = 0,
        .rx_expected_seq = 0,
        .tx_bytes_total = 0,
        .rx_bytes_total = 0,
        .tx_packets_total = 0,
        .rx_packets_total = 0,
        .rx_lost_packets = 0,
        .rx_reordered_packets = 0,
        .rx_duplicate_packets = 0,
        .tx_bps = 0,
        .rx_bps = 0,
        .tx_pps = 0,
        .rx_pps = 0,
        .title_len = 0,
        .title_buf = [_]u8{0} ** 32,
        .role_len = 0,
        .role_buf = [_]u8{0} ** 48,
        .link_len = 0,
        .link_buf = [_]u8{0} ** 80,
        .mtu_len = 0,
        .mtu_buf = [_]u8{0} ** 64,
        .tx_len = 0,
        .tx_buf = [_]u8{0} ** 80,
        .rx_len = 0,
        .rx_buf = [_]u8{0} ** 96,
        .error_len = 0,
        .error_buf = [_]u8{0} ** 48,
    };
    renderText(&state);
    return state;
}

pub fn make(comptime grt: type, comptime ZuxAppType: type) type {
    const Stores = ZuxAppType.Store.Stores;
    const State = @FieldType(Stores, "speed_test").StateType;
    const RoleState = @FieldType(State, "role");
    const PhaseState = @FieldType(State, "phase");
    const log = grt.std.log.scoped(.ble_speed_test);

    return struct {
        const Self = @This();

        pub fn init() Self {
            return .{};
        }

        pub fn reduce(
            self: *Self,
            stores: *Stores,
            message: ZuxAppType.Message,
            emit: ZuxAppType.Emitter,
        ) !void {
            _ = self;
            _ = emit;

            switch (message.body) {
                .ble_periph_advertising_started => |_| applyPhase(stores, .server, .advertising),
                .ble_periph_connected => |event| applyConnected(stores, .server, event.conn_handle, event.interval),
                .ble_periph_connection_updated => |event| applyConnectionUpdated(stores, .server, event.conn_handle, event.interval),
                .ble_periph_mtu_changed => |event| applyMtu(stores, event.conn_handle, event.mtu),
                .ble_periph_disconnected => |event| applyDisconnected(stores, .server, event.conn_handle),
                .ble_central_found => |_| applyPhase(stores, .client, .scanning),
                .ble_central_connected => |event| applyConnected(stores, .client, event.conn_handle, event.interval),
                .ble_central_connection_updated => |event| applyConnectionUpdated(stores, .client, event.conn_handle, event.interval),
                .ble_central_disconnected => |event| applyDisconnected(stores, .client, event.conn_handle),
                .custom => |custom| {
                    if (custom.as(ActionEvent)) |event| {
                        applyAction(stores, event);
                        return;
                    } else |_| {}
                    if (custom.as(StatsDeltaEvent)) |event| {
                        applyStatsDelta(stores, event);
                        return;
                    } else |_| {}
                },
                else => return,
            }
        }

        fn applyPhase(stores: *Stores, role: RoleState, phase: PhaseState) void {
            const Ctx = struct { role: RoleState, phase: PhaseState };
            stores.speed_test.invoke(Ctx{ .role = role, .phase = phase }, struct {
                fn apply(state: *State, ctx: Ctx) void {
                    state.role = ctx.role;
                    state.phase = ctx.phase;
                    renderText(state);
                }
            }.apply);
        }

        fn applyConnected(stores: *Stores, role: RoleState, conn_handle: u16, conn_interval: u16) void {
            const Ctx = struct { role: RoleState, conn_handle: u16, conn_interval: u16 };
            stores.speed_test.invoke(Ctx{ .role = role, .conn_handle = conn_handle, .conn_interval = conn_interval }, struct {
                fn apply(state: *State, ctx: Ctx) void {
                    state.role = ctx.role;
                    state.phase = .stopped;
                    state.running = false;
                    state.connected = true;
                    state.subscribed = false;
                    state.conn_handle = ctx.conn_handle;
                    state.conn_interval = ctx.conn_interval;
                    renderText(state);
                }
            }.apply);
        }

        fn applyConnectionUpdated(stores: *Stores, role: RoleState, conn_handle: u16, conn_interval: u16) void {
            const Ctx = struct { role: RoleState, conn_handle: u16, conn_interval: u16 };
            stores.speed_test.invoke(Ctx{ .role = role, .conn_handle = conn_handle, .conn_interval = conn_interval }, struct {
                fn apply(state: *State, ctx: Ctx) void {
                    if (!state.connected or state.conn_handle != ctx.conn_handle) return;
                    state.role = ctx.role;
                    state.conn_interval = ctx.conn_interval;
                    renderText(state);
                }
            }.apply);
        }

        fn applyMtu(stores: *Stores, conn_handle: u16, mtu: u16) void {
            const Ctx = struct { conn_handle: u16, mtu: u16 };
            stores.speed_test.invoke(Ctx{ .conn_handle = conn_handle, .mtu = mtu }, struct {
                fn apply(state: *State, ctx: Ctx) void {
                    if (state.conn_handle != 0 and state.conn_handle != ctx.conn_handle) return;
                    state.att_mtu = ctx.mtu;
                    state.payload_len = payloadLen(ctx.mtu);
                    renderText(state);
                }
            }.apply);
        }

        fn applyDisconnected(stores: *Stores, role: RoleState, conn_handle: u16) void {
            const Ctx = struct { role: RoleState, conn_handle: u16 };
            stores.speed_test.invoke(Ctx{ .role = role, .conn_handle = conn_handle }, struct {
                fn apply(state: *State, ctx: Ctx) void {
                    if (ctx.conn_handle != 0 and state.conn_handle != 0 and state.conn_handle != ctx.conn_handle) return;
                    state.role = ctx.role;
                    state.phase = passivePhase(ctx.role);
                    state.running = false;
                    state.connected = false;
                    state.subscribed = false;
                    state.conn_handle = 0;
                    renderText(state);
                }
            }.apply);
        }

        fn applyAction(stores: *Stores, event: *ActionEvent) void {
            stores.speed_test.invoke(event, struct {
                fn apply(state: *State, action_event: *ActionEvent) void {
                    switch (action_event.action) {
                        .ready => {
                            if (!matchesConn(state, action_event.conn_handle)) return;
                            state.role = switch (action_event.role) {
                                .client => .client,
                                .server => .server,
                            };
                            state.connected = true;
                            state.subscribed = true;
                            state.conn_handle = action_event.conn_handle;
                            state.conn_interval = action_event.conn_interval;
                            state.att_mtu = action_event.att_mtu;
                            state.payload_len = payloadLen(action_event.att_mtu);
                            state.last_error_code = 0;
                        },
                        .start => {
                            if (!matchesConn(state, action_event.conn_handle) or !state.subscribed) return;
                            resetStats(state);
                            state.phase = .running;
                            state.running = true;
                            state.window_ms = consts.default_window_ms;
                            state.last_error_code = 0;
                            state.last_error_name_len = 0;
                        },
                        .stop => {
                            if (action_event.conn_handle != 0 and !matchesConn(state, action_event.conn_handle)) return;
                            state.running = false;
                            state.subscribed = false;
                            state.connected = false;
                            state.conn_handle = 0;
                            state.phase = passivePhase(state.role);
                        },
                        .reset => resetStats(state),
                        .fail => {
                            state.running = false;
                            state.connected = false;
                            state.subscribed = false;
                            state.conn_handle = 0;
                            state.phase = .failed;
                            state.last_error_code = action_event.error_code;
                            state.last_error_name_len = action_event.error_name_len;
                            state.last_error_name_buf = action_event.error_name_buf;
                        },
                    }
                    renderText(state);
                }
            }.apply);
            switch (event.action) {
                .fail => log.err("action=fail role={s} error_code={} error_name={s}", .{
                    @tagName(event.role),
                    event.error_code,
                    event.error_name_buf[0..event.error_name_len],
                }),
                else => log.debug("action={s} role={s} conn={}", .{ @tagName(event.action), @tagName(event.role), event.conn_handle }),
            }
        }

        fn applyStatsDelta(stores: *Stores, event: *StatsDeltaEvent) void {
            stores.speed_test.invoke(event, struct {
                fn apply(state: *State, delta: *StatsDeltaEvent) void {
                    if (!state.running) return;
                    state.window_ms = delta.window_ms;
                    state.tx_bytes_total +|= delta.tx_bytes;
                    state.rx_bytes_total +|= delta.rx_bytes;
                    state.tx_packets_total +|= delta.tx_packets;
                    state.rx_packets_total +|= delta.rx_packets;
                    state.rx_lost_packets +|= delta.rx_lost_packets;
                    state.rx_reordered_packets +|= delta.rx_reordered_packets;
                    state.rx_expected_seq = delta.rx_expected_seq;
                    state.tx_bps = bitsPerSecond(delta.tx_bytes, delta.window_ms);
                    state.rx_bps = bitsPerSecond(delta.rx_bytes, delta.window_ms);
                    state.tx_pps = packetsPerSecond(delta.tx_packets, delta.window_ms);
                    state.rx_pps = packetsPerSecond(delta.rx_packets, delta.window_ms);
                    renderText(state);
                }
            }.apply);
            log.info(
                "stats delta tx_bytes={d} rx_bytes={d} tx_packets={d} rx_packets={d} rx_lost={d} rx_reordered={d} window_ms={d}",
                .{ event.tx_bytes, event.rx_bytes, event.tx_packets, event.rx_packets, event.rx_lost_packets, event.rx_reordered_packets, event.window_ms },
            );
        }

        fn resetStats(state: *State) void {
            state.tx_seq = 0;
            state.rx_expected_seq = 0;
            state.tx_bytes_total = 0;
            state.rx_bytes_total = 0;
            state.tx_packets_total = 0;
            state.rx_packets_total = 0;
            state.rx_lost_packets = 0;
            state.rx_reordered_packets = 0;
            state.rx_duplicate_packets = 0;
            state.tx_bps = 0;
            state.rx_bps = 0;
            state.tx_pps = 0;
            state.rx_pps = 0;
        }

        fn matchesConn(state: *State, conn_handle: u16) bool {
            return state.connected and conn_handle != 0 and state.conn_handle == conn_handle;
        }

        fn passivePhase(role: RoleState) PhaseState {
            return switch (role) {
                .client => .scanning,
                .server => .advertising,
            };
        }
    };
}

fn payloadLen(mtu: u16) u16 {
    if (mtu <= consts.att_header_len) return 0;
    return @min(mtu - consts.att_header_len, consts.max_payload_len);
}

fn bitsPerSecond(bytes: u32, window_ms: u32) u32 {
    if (window_ms == 0) return 0;
    return @intCast((@as(u64, bytes) * 8 * 1000) / window_ms);
}

fn packetsPerSecond(packets: u32, window_ms: u32) u32 {
    if (window_ms == 0) return 0;
    return @intCast((@as(u64, packets) * 1000) / window_ms);
}

fn kilobits(bps: u32) u32 {
    return bps / 1000;
}

fn kibibytes(bytes: u64) u64 {
    return bytes / 1024;
}

fn intervalMsTenth(interval: u16) u32 {
    return (@as(u32, interval) * 125) / 10;
}

fn renderText(state: anytype) void {
    writeText(&state.title_buf, &state.title_len, "BLE Speed Test", .{});
    writeText(&state.role_buf, &state.role_len, "role: {s}", .{@tagName(state.role)});
    writeText(
        &state.link_buf,
        &state.link_len,
        "{s} conn={d} sub={d}",
        .{ @tagName(state.phase), @intFromBool(state.connected), @intFromBool(state.subscribed) },
    );
    writeText(
        &state.mtu_buf,
        &state.mtu_len,
        "mtu {d} p{d} int {d}.{d}ms",
        .{ state.att_mtu, state.payload_len, intervalMsTenth(state.conn_interval) / 10, intervalMsTenth(state.conn_interval) % 10 },
    );
    writeText(
        &state.tx_buf,
        &state.tx_len,
        "TX {d} KB  {d} Kbps  {d} pps",
        .{ kibibytes(state.tx_bytes_total), kilobits(state.tx_bps), state.tx_pps },
    );
    writeText(
        &state.rx_buf,
        &state.rx_len,
        "RX {d} KB  {d} Kbps  lost {d}",
        .{ kibibytes(state.rx_bytes_total), kilobits(state.rx_bps), state.rx_lost_packets },
    );
    if (state.last_error_name_len > 0) {
        writeText(&state.error_buf, &state.error_len, "err {s} {d}", .{ state.last_error_name_buf[0..state.last_error_name_len], state.last_error_code });
    } else {
        writeText(&state.error_buf, &state.error_len, "err {d}", .{state.last_error_code});
    }
}

fn copyText(buffer: []u8, len_out: *u8, text: []const u8) void {
    const n = @min(buffer.len, text.len);
    @memcpy(buffer[0..n], text[0..n]);
    if (n < buffer.len) @memset(buffer[n..], 0);
    len_out.* = @intCast(n);
}

fn writeText(buffer: anytype, len_out: *u8, comptime fmt: []const u8, args: anytype) void {
    const text = glib.std.fmt.bufPrint(buffer[0..], fmt, args) catch buffer[0..0];
    len_out.* = @intCast(text.len);
}

fn actionField(value: glib.std.json.Value, name: []const u8) !ActionEvent.Action {
    const text = try stringField(value, name);
    if (glib.std.mem.eql(u8, text, "ready")) return .ready;
    if (glib.std.mem.eql(u8, text, "start")) return .start;
    if (glib.std.mem.eql(u8, text, "stop")) return .stop;
    if (glib.std.mem.eql(u8, text, "reset")) return .reset;
    if (glib.std.mem.eql(u8, text, "error")) return .fail;
    if (glib.std.mem.eql(u8, text, "fail")) return .fail;
    return error.InvalidAction;
}

fn roleFieldDefault(value: glib.std.json.Value, name: []const u8, default: consts.Role) consts.Role {
    const text = stringField(value, name) catch return default;
    if (glib.std.mem.eql(u8, text, "client")) return .client;
    if (glib.std.mem.eql(u8, text, "server")) return .server;
    return default;
}

fn stringField(value: glib.std.json.Value, name: []const u8) ![]const u8 {
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidJson,
    };
    const item = object.get(name) orelse return error.MissingField;
    return switch (item) {
        .string => |text| text,
        else => return error.InvalidJson,
    };
}

fn u16FieldDefault(value: glib.std.json.Value, name: []const u8, default: u16) u16 {
    const raw = u32FieldDefault(value, name, default);
    return @intCast(@min(raw, glib.std.math.maxInt(u16)));
}

fn u32FieldDefault(value: glib.std.json.Value, name: []const u8, default: u32) u32 {
    const object = switch (value) {
        .object => |object| object,
        else => return default,
    };
    const item = object.get(name) orelse return default;
    return switch (item) {
        .integer => |v| @intCast(v),
        else => default,
    };
}

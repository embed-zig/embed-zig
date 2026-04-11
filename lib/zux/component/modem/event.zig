const modem_api = @import("modem");
const Context = @import("../../event/Context.zig");

pub const max_apn_len: usize = 32;
pub const Rat = modem_api.Modem.Rat;
pub const SimState = modem_api.Modem.SimState;
pub const RegistrationState = modem_api.Modem.RegistrationState;
pub const PacketState = modem_api.Modem.PacketState;
pub const SignalInfo = modem_api.Modem.SignalInfo;

pub const SimStateChanged = struct {
    pub const kind = .modem_sim_state_changed;

    source_id: u32,
    sim: SimState,
    ctx: Context.Type = null,
};

pub const RegistrationChanged = struct {
    pub const kind = .modem_registration_changed;

    source_id: u32,
    registration: RegistrationState,
    ctx: Context.Type = null,
};

pub const PacketStateChanged = struct {
    pub const kind = .modem_packet_state_changed;

    source_id: u32,
    packet: PacketState,
    ctx: Context.Type = null,
};

pub const SignalChanged = struct {
    pub const kind = .modem_signal_changed;

    source_id: u32,
    signal: SignalInfo,
    ctx: Context.Type = null,
};

pub const ApnChanged = struct {
    pub const kind = .modem_apn_changed;

    source_id: u32,
    apn_end: u8,
    apn_buf: [max_apn_len]u8,
    ctx: Context.Type = null,

    pub fn apn(self: *const @This()) []const u8 {
        return self.apn_buf[0..self.apn_end];
    }
};

pub const Event = modem_api.Modem.Event;
pub const CallbackFn = modem_api.Modem.CallbackFn;

pub fn make(comptime EventType: type, source_id: u32, adapter_event: Event) !EventType {
    return switch (adapter_event) {
        .sim_state_changed => |value| .{
            .modem_sim_state_changed = .{
                .source_id = source_id,
                .sim = value,
                .ctx = null,
            },
        },
        .registration_changed => |value| .{
            .modem_registration_changed = .{
                .source_id = source_id,
                .registration = value,
                .ctx = null,
            },
        },
        .packet_state_changed => |value| .{
            .modem_packet_state_changed = .{
                .source_id = source_id,
                .packet = value,
                .ctx = null,
            },
        },
        .signal_changed => |value| .{
            .modem_signal_changed = .{
                .source_id = source_id,
                .signal = value,
                .ctx = null,
            },
        },
        .apn_changed => |value| .{
            .modem_apn_changed = .{
                .source_id = source_id,
                .apn_end = try copyApnLen(value),
                .apn_buf = try copyApnBuf(value),
                .ctx = null,
            },
        },
    };
}

fn copyApnLen(value: []const u8) !u8 {
    if (value.len > max_apn_len) return error.InvalidApnLength;
    return @intCast(value.len);
}

fn copyApnBuf(value: []const u8) ![max_apn_len]u8 {
    if (value.len > max_apn_len) return error.InvalidApnLength;

    var buf = [_]u8{0} ** max_apn_len;
    @memcpy(buf[0..value.len], value);
    return buf;
}

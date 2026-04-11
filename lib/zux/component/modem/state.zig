const modem_event = @import("event.zig");

pub const Modem = struct {
    source_id: u32 = 0,
    sim: modem_event.SimState = .unknown,
    registration: modem_event.RegistrationState = .offline,
    packet: modem_event.PacketState = .detached,
    signal: ?modem_event.SignalInfo = null,
    apn_end: u8 = 0,
    apn_buf: [modem_event.max_apn_len]u8 = [_]u8{0} ** modem_event.max_apn_len,

    pub fn apn(self: *const @This()) []const u8 {
        return self.apn_buf[0..self.apn_end];
    }
};

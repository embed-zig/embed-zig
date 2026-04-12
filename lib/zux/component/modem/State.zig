const modem_event = @import("event.zig");

const State = @This();

pub const Call = struct {
    call_id: u8 = 0,
    direction: modem_event.CallDirection = .incoming,
    state: ?modem_event.CallState = null,
    end_reason: ?modem_event.CallEndReason = null,
    number_end: u8 = 0,
    number_buf: [modem_event.max_phone_number_len]u8 = [_]u8{0} ** modem_event.max_phone_number_len,

    pub fn number(self: *const @This()) []const u8 {
        return self.number_buf[0..self.number_end];
    }
};

pub const Sms = struct {
    index: ?u16 = null,
    storage: modem_event.SmsStorage = .unknown,
    sender_end: u8 = 0,
    sender_buf: [modem_event.max_phone_number_len]u8 = [_]u8{0} ** modem_event.max_phone_number_len,
    text_end: u16 = 0,
    text_buf: [modem_event.max_sms_text_len]u8 = [_]u8{0} ** modem_event.max_sms_text_len,
    encoding: modem_event.SmsEncoding = .utf8,

    pub fn sender(self: *const @This()) []const u8 {
        return self.sender_buf[0..self.sender_end];
    }

    pub fn text(self: *const @This()) []const u8 {
        return self.text_buf[0..self.text_end];
    }
};

source_id: u32 = 0,
sim: modem_event.SimState = .unknown,
registration: modem_event.RegistrationState = .offline,
packet: modem_event.PacketState = .detached,
signal: ?modem_event.SignalInfo = null,
apn_end: u8 = 0,
apn_buf: [modem_event.max_apn_len]u8 = [_]u8{0} ** modem_event.max_apn_len,
call: ?Call = null,
sms: ?Sms = null,
gnss_state: modem_event.GnssState = .idle,
gnss_fix: ?modem_event.GnssFix = null,

pub fn apn(self: *const State) []const u8 {
    return self.apn_buf[0..self.apn_end];
}

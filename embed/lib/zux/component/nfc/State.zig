const nfc_event = @import("event.zig");

const State = @This();

source_id: u32 = 0,
uid_end: u16 = 0,
payload_end: u16 = 0,
buf: [nfc_event.max_buf_len]u8 = [_]u8{0} ** nfc_event.max_buf_len,
card_type: ?nfc_event.CardType = null,

pub fn uid(self: *const State) []const u8 {
    return self.buf[0..self.uid_end];
}

pub fn payload(self: *const State) []const u8 {
    return self.buf[self.uid_end..self.payload_end];
}

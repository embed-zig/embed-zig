const nfc_api = @import("nfc");

pub const max_uid_len = nfc_api.max_uid_len;
pub const max_payload_len = nfc_api.max_payload_len;
pub const max_buf_len = max_uid_len + max_payload_len;
pub const CardType = nfc_api.CardType;

pub const Found = struct {
    pub const kind = .nfc_found;

    source_id: u32,
    uid_end: u16,
    buf: [max_uid_len]u8,
    card_type: CardType,

    pub fn uid(self: *const @This()) []const u8 {
        return self.buf[0..self.uid_end];
    }
};

pub const Read = struct {
    pub const kind = .nfc_read;

    source_id: u32,
    uid_end: u16,
    payload_end: u16,
    buf: [max_buf_len]u8,
    card_type: CardType,

    pub fn uid(self: *const @This()) []const u8 {
        return self.buf[0..self.uid_end];
    }

    pub fn payload(self: *const @This()) []const u8 {
        return self.buf[self.uid_end..self.payload_end];
    }
};

pub const Lost = struct {
    pub const kind = .nfc_lost;

    source_id: u32,
};

pub const Update = struct {
    source_id: u32,
    uid: []const u8,
    payload: ?[]const u8 = null,
    card_type: CardType,
};

pub fn make(comptime EventType: type, driver_update: nfc_api.Update) !EventType {
    if (!driver_update.present) {
        return .{
            .nfc_lost = .{
                .source_id = driver_update.source_id,
            },
        };
    }

    const update: Update = .{
        .source_id = driver_update.source_id,
        .uid = driver_update.uid,
        .payload = driver_update.payload,
        .card_type = driver_update.card_type,
    };

    if (update.uid.len > max_uid_len) return error.InvalidUidLength;

    const payload = update.payload orelse {
        var uid_buf = [_]u8{0} ** max_uid_len;
        @memcpy(uid_buf[0..update.uid.len], update.uid);
        return .{
            .nfc_found = .{
                .source_id = update.source_id,
                .uid_end = @intCast(update.uid.len),
                .buf = uid_buf,
                .card_type = update.card_type,
            },
        };
    };

    if (payload.len > max_payload_len) return error.InvalidPayloadLength;

    var buf = [_]u8{0} ** max_buf_len;
    @memcpy(buf[0..update.uid.len], update.uid);
    @memcpy(buf[update.uid.len .. update.uid.len + payload.len], payload);

    return .{
        .nfc_read = .{
            .source_id = update.source_id,
            .uid_end = @intCast(update.uid.len),
            .payload_end = @intCast(update.uid.len + payload.len),
            .buf = buf,
            .card_type = update.card_type,
        },
    };
}

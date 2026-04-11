const drivers = @import("drivers");
const Context = @import("../../event/Context.zig");

pub const max_uid_len = drivers.nfc.max_uid_len;
pub const max_payload_len = drivers.nfc.max_payload_len;
pub const max_buf_len = max_uid_len + max_payload_len;
pub const CardType = drivers.nfc.CardType;

pub const Found = struct {
    pub const kind = .nfc_found;

    source_id: u32,
    uid_end: u16,
    buf: [max_uid_len]u8,
    card_type: CardType,
    ctx: Context.Type = null,

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
    ctx: Context.Type = null,

    pub fn uid(self: *const @This()) []const u8 {
        return self.buf[0..self.uid_end];
    }

    pub fn payload(self: *const @This()) []const u8 {
        return self.buf[self.uid_end..self.payload_end];
    }
};

pub const Update = struct {
    source_id: u32,
    uid: []const u8,
    payload: ?[]const u8 = null,
    card_type: CardType,
    ctx: Context.Type = null,
};

pub fn make(comptime EventType: type, driver_update: drivers.nfc.Update, ctx: Context.Type) !EventType {
    const update: Update = .{
        .source_id = driver_update.source_id,
        .uid = driver_update.uid,
        .payload = driver_update.payload,
        .card_type = driver_update.card_type,
        .ctx = ctx,
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
                .ctx = update.ctx,
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
            .ctx = update.ctx,
        },
    };
}

const embed = @import("embed_core");
const bk = @import("../../bk.zig");

pub const ok: c_int = 0;
pub const timeout: c_int = 1;

pub extern fn bk_embed_bt_local_hci_init() c_int;
pub extern fn bk_embed_bt_local_hci_deinit() void;
pub extern fn bk_embed_bt_local_hci_send(data: [*]const u8, len: usize, timeout_ms: u32) c_int;
pub extern fn bk_embed_bt_local_hci_recv(out: [*]u8, cap: usize, out_len: *usize, timeout_ms: u32) c_int;

pub const Transport = struct {
    read_deadline: ?bk.ap.grt.time.instant.Time = null,
    write_deadline: ?bk.ap.grt.time.instant.Time = null,

    pub fn init() Transport {
        return .{};
    }

    pub fn handle(self: *Transport) embed.bt.Transport {
        return embed.bt.Transport.init(self);
    }

    pub fn read(self: *Transport, buf: []u8) embed.bt.Transport.ReadError!usize {
        var len: usize = 0;
        const rc = bk_embed_bt_local_hci_recv(buf.ptr, buf.len, &len, timeoutMs(self.read_deadline));
        if (rc == ok) return len;
        if (rc == timeout) return error.Timeout;
        return error.HwError;
    }

    pub fn write(self: *Transport, buf: []const u8) embed.bt.Transport.WriteError!usize {
        const rc = bk_embed_bt_local_hci_send(buf.ptr, buf.len, timeoutMs(self.write_deadline));
        if (rc == ok) return buf.len;
        if (rc == timeout) return error.Timeout;
        return error.HwError;
    }

    pub fn reset(_: *Transport) void {}

    pub fn deinit(_: *Transport) void {
        bk_embed_bt_local_hci_deinit();
    }

    pub fn setReadDeadline(self: *Transport, deadline: ?bk.ap.grt.time.instant.Time) void {
        self.read_deadline = deadline;
    }

    pub fn setWriteDeadline(self: *Transport, deadline: ?bk.ap.grt.time.instant.Time) void {
        self.write_deadline = deadline;
    }
};

pub fn init() !void {
    try check("bk_embed_bt_local_hci_init", bk_embed_bt_local_hci_init());
}

fn timeoutMs(deadline: ?bk.ap.grt.time.instant.Time) u32 {
    const value = deadline orelse return 0xffffffff;
    const now = bk.ap.grt.time.instant.now();
    if (value <= now) return 0;
    const delta_ns: i64 = @intCast(value - now);
    const ms = @divTrunc(delta_ns, bk.ap.grt.time.duration.MilliSecond);
    if (ms > bk.ap.grt.std.math.maxInt(u32)) return bk.ap.grt.std.math.maxInt(u32);
    return @intCast(ms);
}

fn check(name: []const u8, rc: c_int) !void {
    if (rc == ok) return;
    bk.ap.grt.std.log.scoped(.bk_bt_local_hci).err("{s} failed with rc={d}", .{ name, rc });
    return error.LocalHciFailed;
}

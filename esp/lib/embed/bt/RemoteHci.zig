const embed = @import("embed_core");
const esp = @import("esp");

pub const esp_ok: c_int = 0;
pub const esp_timeout: c_int = 0x107;

pub extern fn esp_embed_bt_remote_hci_init() c_int;
pub extern fn esp_embed_bt_remote_hci_send(data: [*]const u8, len: usize, timeout_ms: u32) c_int;
pub extern fn esp_embed_bt_remote_hci_recv(out: [*]u8, cap: usize, out_len: *usize, timeout_ms: u32) c_int;

pub const Transport = struct {
    read_deadline: ?esp.grt.time.instant.Time = null,
    write_deadline: ?esp.grt.time.instant.Time = null,

    pub fn init() Transport {
        return .{};
    }

    pub fn handle(self: *Transport) embed.bt.Transport {
        return embed.bt.Transport.init(self);
    }

    pub fn read(self: *Transport, buf: []u8) embed.bt.Transport.ReadError!usize {
        var len: usize = 0;
        const rc = esp_embed_bt_remote_hci_recv(buf.ptr, buf.len, &len, timeoutMs(self.read_deadline));
        if (rc == esp_ok) return len;
        if (rc == esp_timeout) return error.Timeout;
        return error.HwError;
    }

    pub fn write(self: *Transport, buf: []const u8) embed.bt.Transport.WriteError!usize {
        const rc = esp_embed_bt_remote_hci_send(buf.ptr, buf.len, timeoutMs(self.write_deadline));
        if (rc == esp_ok) return buf.len;
        if (rc == esp_timeout) return error.Timeout;
        return error.HwError;
    }

    pub fn reset(_: *Transport) void {}
    pub fn deinit(_: *Transport) void {}

    pub fn setReadDeadline(self: *Transport, deadline: ?esp.grt.time.instant.Time) void {
        self.read_deadline = deadline;
    }

    pub fn setWriteDeadline(self: *Transport, deadline: ?esp.grt.time.instant.Time) void {
        self.write_deadline = deadline;
    }
};

pub fn init() !void {
    try check("esp_embed_bt_remote_hci_init", esp_embed_bt_remote_hci_init());
}

fn timeoutMs(deadline: ?esp.grt.time.instant.Time) u32 {
    const value = deadline orelse return 0xffffffff;
    const now = esp.grt.time.instant.now();
    if (value <= now) return 0;
    const delta_ns: i64 = @intCast(value - now);
    const ms = @divTrunc(delta_ns, esp.grt.time.duration.MilliSecond);
    if (ms > esp.grt.std.math.maxInt(u32)) return esp.grt.std.math.maxInt(u32);
    return @intCast(ms);
}

fn check(name: []const u8, rc: c_int) !void {
    if (rc == esp_ok) return;
    esp.grt.std.log.scoped(.esp_bt_remote_hci).err("{s} failed with rc={d}", .{ name, rc });
    return error.RemoteHciFailed;
}

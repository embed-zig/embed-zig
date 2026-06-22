const glib = @import("glib");
const armino = @import("bk_armino");

extern fn bk_printf(format: [*:0]const u8, ...) c_int;

const ApLogIpc = armino.ipc.Channel(.{
    .name = "bk_ap_log_ipc",
    .receive = receiveApLog,
});

comptime {
    _ = ApLogIpc;
}

pub fn write(
    comptime level: anytype,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    var line_buf: [256:0]u8 = undefined;
    const level_text = comptime levelText(level);
    const scope_text = comptime @tagName(scope);

    const line = glib.std.fmt.bufPrintZ(
        &line_buf,
        "[CP] [{s}] [{s}] " ++ format ++ "\r\n",
        .{ level_text, scope_text } ++ args,
    ) catch {
        const fallback = glib.std.fmt.bufPrintZ(
            &line_buf,
            "[CP] [{s}] [{s}] <log message truncated>\r\n",
            .{ level_text, scope_text },
        ) catch return;
        _ = bk_printf("%s", fallback.ptr);
        return;
    };

    _ = bk_printf("%s", line.ptr);
}

fn receiveApLog(data: []const u8) void {
    const text = glib.std.mem.sliceTo(data, 0);
    var line_buf: [288:0]u8 = undefined;
    const line = glib.std.fmt.bufPrintZ(&line_buf, "{s}\r\n", .{text}) catch return;
    armino.system.emergencyUartWriteString(0, line);
}

fn levelText(comptime level: anytype) []const u8 {
    const name = comptime @tagName(level);
    if (comptime glib.std.mem.eql(u8, name, "err")) return "error";
    if (comptime glib.std.mem.eql(u8, name, "warn")) return "warning";
    return name;
}

const glib = @import("glib");
const armino = @import("bk_armino");

const ApLogIpc = armino.ipc.Channel(.{
    .name = "bk_ap_log_ipc",
});

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
        "[AP] [{s}] [{s}] " ++ format,
        .{ level_text, scope_text } ++ args,
    ) catch {
        const fallback = glib.std.fmt.bufPrintZ(
            &line_buf,
            "[AP] [{s}] [{s}] <log message truncated>",
            .{ level_text, scope_text },
        ) catch return;
        _ = ApLogIpc.sendZ(fallback, .{ .sync = true }) catch {};
        return;
    };

    _ = ApLogIpc.sendZ(line, .{ .sync = true }) catch {};
}

fn levelText(comptime level: anytype) []const u8 {
    const name = comptime @tagName(level);
    if (comptime glib.std.mem.eql(u8, name, "err")) return "error";
    if (comptime glib.std.mem.eql(u8, name, "warn")) return "warning";
    return name;
}

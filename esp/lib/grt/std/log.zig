const glib = @import("glib");

extern fn ets_printf(fmt: [*:0]const u8, ...) callconv(.c) c_int;

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
        "[{s}] [{s}] " ++ format ++ "\n",
        .{ level_text, scope_text } ++ args,
    ) catch {
        const fallback = glib.std.fmt.bufPrintZ(
            &line_buf,
            "[{s}] [{s}] <log message truncated>\n",
            .{ level_text, scope_text },
        ) catch return;
        _ = ets_printf("%s", fallback.ptr);
        return;
    };

    _ = ets_printf("%s", line.ptr);
}

fn levelText(comptime level: anytype) []const u8 {
    const name = comptime @tagName(level);
    if (comptime glib.std.mem.eql(u8, name, "err")) return "error";
    if (comptime glib.std.mem.eql(u8, name, "warn")) return "warning";
    return name;
}

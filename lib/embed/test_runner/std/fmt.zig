pub fn run(comptime lib: type) !void {
    const log = lib.log.scoped(.fmt);
    const allocator = lib.testing.allocator;

    {
        var buf: [64]u8 = undefined;
        const formatted = try lib.fmt.bufPrint(&buf, "hello {s} #{d}", .{ "embed", 7 });
        if (!lib.mem.eql(u8, formatted, "hello embed #7")) return error.BufPrintMismatch;
        log.info("bufPrint ok", .{});
    }

    {
        const allocated = try lib.fmt.allocPrint(allocator, "{s}:{x}", .{ "port", 0xBEEF });
        defer allocator.free(allocated);
        if (!lib.mem.eql(u8, allocated, "port:beef")) return error.AllocPrintMismatch;
        log.info("allocPrint ok", .{});
    }

    {
        const parsed_dec = try lib.fmt.parseInt(u16, "8080", 10);
        const parsed_hex = try lib.fmt.parseInt(u16, "ff", 16);
        if (parsed_dec != 8080) return error.ParseIntDecimalFailed;
        if (parsed_hex != 255) return error.ParseIntHexFailed;
        log.info("parseInt ok", .{});
    }
}

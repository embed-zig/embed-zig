pub fn run(comptime lib: type) !void {
    const log = lib.log.scoped(.mem);

    _ = lib.mem.Allocator;
    log.info("mem.Allocator type present", .{});

    const val: u16 = 0x1234;
    const big = lib.mem.nativeToBig(u16, val);
    const back = lib.mem.bigToNative(u16, big);
    if (back != val) return error.EndianRoundtripFailed;
    log.info("nativeToBig/bigToNative u16 roundtrip ok", .{});

    const val32: u32 = 0xDEADBEEF;
    const big32 = lib.mem.nativeToBig(u32, val32);
    const back32 = lib.mem.bigToNative(u32, big32);
    if (back32 != val32) return error.Endian32RoundtripFailed;
    log.info("nativeToBig/bigToNative u32 roundtrip ok", .{});

    {
        var bytes: [4]u8 = undefined;
        lib.mem.writeInt(u32, &bytes, 0x12345678, .big);
        const got_be = lib.mem.readInt(u32, &bytes, .big);
        const got_le = lib.mem.readInt(u32, &bytes, .little);
        if (got_be != 0x12345678) return error.ReadWriteIntBigEndianFailed;
        if (got_le != 0x78563412) return error.ReadWriteIntLittleEndianMismatch;
        log.info("readInt/writeInt ok", .{});
    }

    {
        if (!lib.mem.eql(u8, "embed", "embed")) return error.MemEqlEqualFailed;
        if (lib.mem.eql(u8, "embed", "std")) return error.MemEqlDifferentFailed;
        log.info("eql ok", .{});
    }

    {
        const needle = lib.mem.indexOf(u8, "hello embed world", "embed") orelse return error.IndexOfFailed;
        if (needle != 6) return error.IndexOfWrongOffset;

        if (lib.mem.indexOf(u8, "hello embed world", "zig") != null) return error.IndexOfUnexpectedMatch;

        const first_colon = lib.mem.indexOfScalar(u8, "a:b:c", ':') orelse return error.IndexOfScalarFailed;
        const last_colon = lib.mem.lastIndexOfScalar(u8, "a:b:c", ':') orelse return error.LastIndexOfScalarFailed;
        if (first_colon != 1) return error.IndexOfScalarWrongOffset;
        if (last_colon != 3) return error.LastIndexOfScalarWrongOffset;
        log.info("indexOf/indexOfScalar/lastIndexOfScalar ok", .{});
    }

    {
        const trimmed = lib.mem.trim(u8, " \t  hello embed \n", &lib.ascii.whitespace);
        if (!lib.mem.eql(u8, trimmed, "hello embed")) return error.TrimFailed;
        log.info("trim ok", .{});
    }
}

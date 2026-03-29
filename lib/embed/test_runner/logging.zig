pub fn suiteStart(comptime lib: type, comptime Logger: type, comptime name: []const u8) i64 {
    const started_ms = lib.time.milliTimestamp();
    logOpened(Logger, name, 0);
    return started_ms;
}

pub fn suiteDone(comptime lib: type, comptime Logger: type, comptime name: []const u8, started_ms: i64) void {
    const finished_ms = lib.time.milliTimestamp();
    const total_ms = elapsedMs(finished_ms - started_ms);
    logClosed(Logger, name, total_ms, total_ms);
}

pub fn runCase(
    comptime lib: type,
    comptime Logger: type,
    suite_started_ms: i64,
    comptime name: []const u8,
    comptime CaseFn: anytype,
) !void {
    const case_started_ms = lib.time.milliTimestamp();
    logOpened(Logger, name, elapsedMs(case_started_ms - suite_started_ms));
    errdefer {
        const failed_ms = lib.time.milliTimestamp();
        logFailed(
            Logger,
            name,
            elapsedMs(failed_ms - suite_started_ms),
            elapsedMs(failed_ms - case_started_ms),
        );
    }
    try CaseFn();
    const finished_ms = lib.time.milliTimestamp();
    logClosed(
        Logger,
        name,
        elapsedMs(finished_ms - suite_started_ms),
        elapsedMs(finished_ms - case_started_ms),
    );
}

fn logOpened(comptime Logger: type, comptime name: []const u8, total_ms: u64) void {
    Logger.info(">>> {s} {d}.{d:0>1}s", .{
        name,
        total_ms / 1000,
        (total_ms % 1000) / 100,
    });
}

fn logClosed(comptime Logger: type, comptime name: []const u8, total_ms: u64, delta_ms: u64) void {
    Logger.info("<<< {s} {d}.{d:0>1}s, {d}ms", .{
        name,
        total_ms / 1000,
        (total_ms % 1000) / 100,
        delta_ms,
    });
}

fn logFailed(comptime Logger: type, comptime name: []const u8, total_ms: u64, delta_ms: u64) void {
    Logger.err("!!! {s} {d}.{d:0>1}s, {d}ms", .{
        name,
        total_ms / 1000,
        (total_ms % 1000) / 100,
        delta_ms,
    });
}

fn elapsedMs(delta_ms: i64) u64 {
    return if (delta_ms <= 0) 0 else @intCast(delta_ms);
}

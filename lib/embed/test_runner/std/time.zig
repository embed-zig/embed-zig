pub fn run(comptime lib: type) !void {
    const log = lib.log.scoped(.time);

    const t1 = lib.time.milliTimestamp();
    lib.Thread.sleep(10_000_000);
    const t2 = lib.time.milliTimestamp();
    const elapsed = t2 - t1;
    if (elapsed < 5) return error.TimestampTooFast;
    log.info("milliTimestamp elapsed={}ms", .{elapsed});

    if (t1 <= 0) return error.TimestampNonPositive;

    const ns1 = lib.time.nanoTimestamp();
    lib.Thread.sleep(1_000_000);
    const ns2 = lib.time.nanoTimestamp();
    const elapsed_ns = ns2 - ns1;
    if (elapsed_ns <= 0) return error.NanoTimestampNonMonotonic;
    log.info("nanoTimestamp elapsed={}ns", .{elapsed_ns});

    {
        var timer = try lib.time.Timer.start();
        lib.Thread.sleep(10_000_000);
        const r1 = timer.read();
        if (r1 < 5 * lib.time.ns_per_ms) return error.TimerReadTooSmall;
        log.info("Timer.read={}ns", .{r1});

        const lap_val = timer.lap();
        if (lap_val < r1) return error.TimerLapTooSmall;
        log.info("Timer.lap={}ns", .{lap_val});

        lib.Thread.sleep(1_000_000);
        const after_lap = timer.read();
        if (after_lap >= lap_val) return error.TimerLapDidNotReset;
        if (after_lap < lib.time.ns_per_ms / 2) return error.TimerLapReadTooSmall;
        log.info("Timer.lap reset ok, read after lap={}ns", .{after_lap});

        timer.reset();
        lib.Thread.sleep(1_000_000);
        const after_reset = timer.read();
        if (after_reset >= lap_val) return error.TimerResetFailed;
        if (after_reset < lib.time.ns_per_ms / 2) return error.TimerResetReadTooSmall;
        log.info("Timer.reset ok, read={}ns", .{after_reset});
    }

    log.info("time done", .{});
}

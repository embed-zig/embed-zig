pub fn run(comptime lib: type) !void {
    const log = lib.log.scoped(.time);

    const t1 = lib.time.milliTimestamp();
    lib.Thread.sleep(10_000_000);
    const t2 = lib.time.milliTimestamp();
    const elapsed = t2 - t1;
    if (elapsed < 5) return error.TimestampTooFast;
    log.info("milliTimestamp elapsed={}ms", .{elapsed});

    if (t1 <= 0) return error.TimestampNonPositive;

    {
        var timer = try lib.time.Timer.start();
        lib.Thread.sleep(10_000_000);
        const r1 = timer.read();
        if (r1 == 0) return error.TimerReadZero;
        log.info("Timer.read={}", .{r1});

        const lap_val = timer.lap();
        if (lap_val < r1) return error.TimerLapTooSmall;
        log.info("Timer.lap={}", .{lap_val});

        lib.Thread.sleep(1_000_000);
        const after_lap = timer.read();
        if (after_lap >= lap_val) return error.TimerLapDidNotReset;
        log.info("Timer.lap reset ok, read after lap={}", .{after_lap});

        timer.reset();
        lib.Thread.sleep(1_000_000);
        const after_reset = timer.read();
        if (after_reset >= lap_val) return error.TimerResetFailed;
        log.info("Timer.reset ok, read={}", .{after_reset});
    }

    log.info("time done", .{});
}

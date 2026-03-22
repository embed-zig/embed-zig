pub fn run(comptime lib: type) !void {
    const scoped = lib.log.scoped(.log_test);
    scoped.warn("scoped warn level", .{});
    scoped.info("scoped info level", .{});
    scoped.debug("scoped debug level", .{});

    lib.log.warn("default warn", .{});
    lib.log.info("default info", .{});
    lib.log.debug("default debug", .{});

    lib.log.info("format test: int={} str={s} float={d:.2}", .{ 42, "hello", 3.14 });
}

const glib = @import("glib");

pub const impl = struct {
    pub fn make(comptime grt: type) type {
        comptime var builder = glib.task.Builder();
        builder.handle("", DefaultHandler(grt));
        builder.onError(ErrorHandler);
        return builder.make();
    }
};

pub fn DefaultHandler(comptime grt: type) type {
    return struct {
        pub const Handle = grt.std.Thread;
        pub const SpawnError = grt.std.Thread.SpawnError;

        pub fn go(
            name: []const u8,
            options: glib.task.Options,
            routine: glib.task.Routine,
        ) grt.std.Thread.SpawnError!grt.std.Thread {
            var name_buf: [grt.std.Thread.max_name_len:0]u8 = undefined;
            const task_name = taskName(grt, name, &name_buf);

            return grt.std.Thread.spawn(.{
                .name = task_name.ptr,
                .stack_size = options.min_stack_size,
            }, runRoutine, .{routine});
        }
    };
}

fn runRoutine(routine: glib.task.Routine) void {
    routine.run();
}

const ErrorHandler = struct {
    pub fn onError(_: []const u8, _: anyerror) void {
        @panic("esp task.go failed");
    }
};

fn taskName(comptime grt: type, name: []const u8, buf: *[grt.std.Thread.max_name_len:0]u8) [:0]const u8 {
    const fallback = "task";
    const source = if (name.len == 0) fallback else name;
    const max_len = grt.std.Thread.max_name_len;
    const len = @min(source.len, max_len);

    for (source[0..len], 0..) |c, i| {
        buf[i] = switch (c) {
            '/', '.', ' ', ':' => '_',
            else => c,
        };
    }
    buf[len] = 0;
    return buf[0..len :0];
}

const glib = @import("glib");
const thread_common = @import("std/ThreadCommon.zig");

pub fn Impl(comptime Thread: type) type {
    return struct {
        pub fn make(comptime grt: type) type {
            comptime var builder = glib.task.Builder();
            builder.handle("", DefaultHandler(grt, Thread));
            builder.onError(ErrorHandler);
            return builder.make();
        }
    };
}

pub const impl = struct {
    pub fn make(comptime grt: type) type {
        _ = grt;
        @compileError("bk task.impl requires an explicit platform Thread; use task.Impl(Thread)");
    }
};

pub fn DefaultHandler(comptime grt: type, comptime Thread: type) type {
    _ = grt;
    return struct {
        pub const Handle = Thread;
        pub const SpawnError = glib.std.Thread.SpawnError;

        pub fn go(
            name: []const u8,
            options: glib.task.Options,
            routine: glib.task.Routine,
        ) SpawnError!Handle {
            var name_buf: [Thread.max_name_len:0]u8 = undefined;
            const task_name = taskName(name, &name_buf, Thread.max_name_len);

            return Thread.spawn(.{
                .name = task_name.ptr,
                .stack_size = options.min_stack_size,
            }, runRoutine, .{routine});
        }

        pub fn currentToken() usize {
            return thread_common.currentThreadToken();
        }
    };
}

const ErrorHandler = struct {
    pub fn onError(_: []const u8, _: anyerror) void {
        @panic("bk task.go failed");
    }
};

fn taskName(name: []const u8, buf: anytype, comptime max_len: usize) [:0]const u8 {
    const fallback = "task";
    const source = if (name.len == 0) fallback else name;
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

fn runRoutine(routine: glib.task.Routine) void {
    routine.run();
}

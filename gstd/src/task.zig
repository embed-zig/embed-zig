const glib = @import("glib");
const std = @import("std");

pub const impl = struct {
    pub fn make(comptime grt: type) type {
        _ = grt;
        comptime var builder = glib.task.Builder();
        builder.handle("", DefaultHandler);
        builder.onError(ErrorHandler);
        return builder.make();
    }
};

const DefaultHandler = struct {
    pub const Handle = std.Thread;
    pub const SpawnError = std.Thread.SpawnError;

    pub fn go(
        _: []const u8,
        options: glib.task.Options,
        routine: glib.task.Routine,
    ) SpawnError!Handle {
        return std.Thread.spawn(.{
            .stack_size = stackSize(options.min_stack_size),
        }, runRoutine, .{routine});
    }

    pub fn currentToken() usize {
        const value: usize = @intCast(std.Thread.getCurrentId());
        return if (value == 0) 1 else value;
    }
};

const ErrorHandler = struct {
    pub fn onError(_: []const u8, _: anyerror) void {
        @panic("gstd task.go failed");
    }
};

fn runRoutine(routine: glib.task.Routine) void {
    routine.run();
}

fn stackSize(min_stack_size: usize) usize {
    if (min_stack_size == 0) return std.Thread.SpawnConfig.default_stack_size;
    return min_stack_size;
}

const glib = @import("glib");
const Native = @import("task/Native.zig");

pub fn Impl(comptime policy: anytype) type {
    return struct {
        pub fn make(comptime grt: type) type {
            @setEvalBranchQuota(100_000);

            comptime var builder = glib.task.Builder();

            const fields = @typeInfo(@TypeOf(policy)).@"struct".fields;
            inline for (fields) |field| {
                builder.handle(field.name, PolicyHandler(grt, policyEntry(@field(policy, field.name))));
            }

            builder.onError(ErrorHandler(grt));
            return builder.make();
        }
    };
}

const Entry = struct {
    stack_size: ?usize = null,
    priority: ?u8 = null,
    core_id: ?i32 = null,
    stack_memory: ?Native.StackMemory = null,
};

fn PolicyHandler(comptime grt: type, comptime entry: Entry) type {
    return struct {
        pub const Handle = Native;
        pub const SpawnError = Native.SpawnError;

        pub fn go(
            name: []const u8,
            options: glib.task.Options,
            routine: glib.task.Routine,
        ) SpawnError!Handle {
            var name_buf: [Native.max_name_len:0]u8 = undefined;
            const task_name = taskName(grt, name, &name_buf);

            var spawn_config: Native.SpawnConfig = .{
                .name = task_name.ptr,
                .stack_size = entry.stack_size orelse options.min_stack_size,
            };
            if (entry.priority) |priority| spawn_config.priority = priority;
            if (entry.core_id) |core_id| spawn_config.core_id = core_id;
            if (entry.stack_memory) |stack_memory| spawn_config.stack_memory = stack_memory;

            return Native.spawn(spawn_config, routine);
        }

        pub fn currentToken() usize {
            return Native.currentToken();
        }
    };
}

fn ErrorHandler(comptime grt: type) type {
    return struct {
        const log = grt.std.log.scoped(.grt_task);

        pub fn onError(name: []const u8, err: anyerror) void {
            log.err("task.go rejected name={s} err={s}", .{ name, @errorName(err) });
            @panic("esp task.go rejected");
        }
    };
}

fn policyEntry(comptime value: anytype) Entry {
    const Value = @TypeOf(value);
    return switch (@typeInfo(Value)) {
        .@"struct" => .{
            .stack_size = if (@hasField(Value, "stack_size")) value.stack_size else null,
            .priority = if (@hasField(Value, "priority")) value.priority else null,
            .core_id = if (@hasField(Value, "core_id")) value.core_id else null,
            .stack_memory = if (@hasField(Value, "stack_memory")) value.stack_memory else null,
        },
        else => @compileError("task policy entry must be a struct"),
    };
}

fn taskName(comptime grt: type, name: []const u8, buf: *[Native.max_name_len:0]u8) [:0]const u8 {
    _ = grt;
    const fallback = "task";
    const source = if (name.len == 0) fallback else name;
    const max_len = Native.max_name_len;
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

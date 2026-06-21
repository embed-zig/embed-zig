pub const meta = .{
    .source_file = sourceFile(),
    .module = "gstd/runtime/task",
    .filter = "gstd/runtime/task",
    .label = .unit,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");

const main_task_options: glib.task.Options = .{ .min_stack_size = 4 * 1024 };
const batch_task_options: glib.task.Options = .{ .min_stack_size = 4 * 1024 };

test "gstd/runtime/task" {
    const std = @import("std");

    var state: usize = 0;
    const routine = glib.task.Routine.init(&state, struct {
        fn run(value: *usize) void {
            value.* += 1;
        }
    }.run);
    const handle = try gstd.runtime.task.go("testing/gstd/main", main_task_options, routine);
    handle.join();

    try std.testing.expectEqual(@as(usize, 1), state);
}

test "gstd/runtime/task joins multiple pooled jobs" {
    const std = @import("std");

    var values = [_]usize{ 0, 0, 0, 0, 0, 0, 0, 0 };
    var handles: [values.len]gstd.runtime.task.Handle = undefined;

    for (&values, &handles) |*value, *handle| {
        const routine = glib.task.Routine.init(value, struct {
            fn run(slot: *usize) void {
                slot.* += 1;
            }
        }.run);
        handle.* = try gstd.runtime.task.go("testing/gstd/batch", batch_task_options, routine);
    }

    for (handles) |handle| {
        handle.join();
    }

    for (values) |value| {
        try std.testing.expectEqual(@as(usize, 1), value);
    }
}

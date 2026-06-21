pub const meta = .{
    .source_file = sourceFile(),
    .module = "gstd/runtime/task",
    .filter = "gstd/runtime/task/explicit stack",
    .label = .unit,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");

test "gstd/runtime/task/explicit stack" {
    var ran = false;
    const handle = try gstd.runtime.task.go(
        "testing/gstd/explicit_stack",
        .{ .min_stack_size = 1 },
        glib.task.Routine.init(&ran, struct {
            fn run(value: *bool) void {
                value.* = true;
            }
        }.run),
    );
    handle.join();

    try gstd.runtime.std.testing.expect(ran);
}

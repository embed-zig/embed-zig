pub const meta = .{
    .source_file = sourceFile(),
    .module = "gstd/runtime",
    .filter = "gstd/runtime/unit/thread/gstd small explicit stack",
    .label = .unit,
};

fn sourceFile() []const u8 {
    return @src().file;
}

const glib = @import("glib");
const gstd = @import("gstd");

test "gstd/runtime/unit/thread/gstd small explicit stack" {
    const thread = try gstd.runtime.std.Thread.spawn(.{ .stack_size = 1 }, struct {
        fn run() void {}
    }.run, .{});
    thread.join();
}

const Executor = @import("Executor.zig");
const Output = @import("Output.zig");

pub fn executeLine(executor: Executor, line: []const u8, out: Output) !void {
    executor.execute(line, out) catch |err| {
        try writeError(out, err);
    };
    try out.flush();
}

fn writeError(out: Output, err: anyerror) !void {
    try out.writeAll("error: ");
    try out.writeAll(@errorName(err));
    try out.writeAll("\n");
}

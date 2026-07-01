const Executor = @import("Executor.zig");
const Output = @import("Output.zig");

pub fn StreamOutput(comptime Stream: type) type {
    return struct {
        stream: *Stream,

        pub fn init(stream: *Stream) @This() {
            return .{ .stream = stream };
        }

        pub fn write(self: *@This(), bytes: []const u8) !usize {
            try self.stream.write(bytes);
            return bytes.len;
        }
    };
}

pub fn executeLine(comptime Stream: type, executor: Executor, stream: *Stream, line: []const u8) !void {
    var output_impl = StreamOutput(Stream).init(stream);
    const out = Output.make(StreamOutput(Stream)).init(&output_impl);
    executor.execute(line, out) catch |err| {
        try out.writeAll("error: ");
        try out.writeAll(@errorName(err));
        try out.writeAll("\n");
    };
}

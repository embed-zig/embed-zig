const Executor = @import("Executor.zig");
const Output = @import("Output.zig");

pub const default_addr = "127.0.0.1";
pub const default_port: u16 = 39074;

pub const Config = struct {
    addr: []const u8 = default_addr,
    port: u16 = default_port,
};

pub fn StreamOutput(comptime Stream: type) type {
    return struct {
        stream: *Stream,

        pub fn init(stream: *Stream) @This() {
            return .{ .stream = stream };
        }

        pub fn write(self: *@This(), bytes: []const u8) !usize {
            return self.stream.write(bytes);
        }

        pub fn flush(self: *@This()) !void {
            if (@hasDecl(Stream, "flush")) try self.stream.flush();
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
    try out.flush();
}

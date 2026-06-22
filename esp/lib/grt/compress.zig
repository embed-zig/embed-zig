const glib = @import("glib");
const binding = @import("compress/binding.zig");

const compress = glib.compress;

pub const impl = struct {
    pub const supports_stream = true;

    pub fn inflate(container: compress.Container, compressed: []const u8, out: []u8) compress.InflateError!usize {
        var written: usize = 0;
        const status = binding.espz_compress_inflate(
            @intFromEnum(container),
            compressed.ptr,
            compressed.len,
            out.ptr,
            out.len,
            &written,
        );
        return switch (status) {
            binding.ok => written,
            binding.invalid_data => error.InvalidData,
            binding.truncated_input => error.TruncatedInput,
            binding.output_too_small => error.OutputTooSmall,
            binding.unsupported => error.Unsupported,
            else => error.Unexpected,
        };
    }

    pub fn inflateStream(container: compress.Container, compressed: []const u8, sink: anytype) !usize {
        const Context = struct {
            sink: @TypeOf(sink),
            err: ?anyerror = null,
        };
        var ctx: Context = .{ .sink = sink };
        var written: usize = 0;
        const Callback = struct {
            fn call(data: [*]const u8, len: usize, user_ctx: ?*anyopaque) callconv(.c) c_int {
                const context: *Context = @ptrCast(@alignCast(user_ctx.?));
                context.sink.write(data[0..len]) catch |err| {
                    context.err = err;
                    return 0;
                };
                return 1;
            }
        };
        const status = binding.espz_compress_inflate_stream(
            @intFromEnum(container),
            compressed.ptr,
            compressed.len,
            Callback.call,
            &ctx,
            &written,
        );
        if (status == binding.callback_error) {
            if (ctx.err) |err| return err;
            return error.Unexpected;
        }
        return switch (status) {
            binding.ok => written,
            binding.invalid_data => error.InvalidData,
            binding.truncated_input => error.TruncatedInput,
            binding.output_too_small => error.OutputTooSmall,
            binding.unsupported => error.Unsupported,
            else => error.Unexpected,
        };
    }
};

const glib = @import("glib");
const binding = @import("binding.zig");
const Error = @import("types.zig").Error;

pub fn checkError(code: c_int) Error!void {
    if (code < 0) {
        return switch (code) {
            binding.OPUS_BAD_ARG => Error.BadArg,
            binding.OPUS_BUFFER_TOO_SMALL => Error.BufferTooSmall,
            binding.OPUS_INTERNAL_ERROR => Error.InternalError,
            binding.OPUS_INVALID_PACKET => Error.InvalidPacket,
            binding.OPUS_UNIMPLEMENTED => Error.Unimplemented,
            binding.OPUS_INVALID_STATE => Error.InvalidState,
            binding.OPUS_ALLOC_FAIL => Error.AllocFail,
            else => Error.Unknown,
        };
    }
}

pub fn checkedPositive(code: c_int) Error!usize {
    try checkError(code);
    return @intCast(code);
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            grt.std.testing.expectError(Error.BadArg, checkError(binding.OPUS_BAD_ARG)) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            grt.std.testing.expectError(Error.InvalidState, checkError(binding.OPUS_INVALID_STATE)) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            checkError(0) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            checkError(3) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}

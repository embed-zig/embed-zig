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

pub fn TestRunner(comptime lib: type) @import("testing").TestRunner {
    const testing_api = @import("testing");

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            lib.testing.expectError(Error.BadArg, checkError(binding.OPUS_BAD_ARG)) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            lib.testing.expectError(Error.InvalidState, checkError(binding.OPUS_INVALID_STATE)) catch |err| {
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

        pub fn deinit(self: *@This(), allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}

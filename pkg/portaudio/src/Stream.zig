const glib = @import("glib");
const binding = @import("binding.zig");
const error_mod = @import("error.zig");
const types = @import("types.zig");

const Self = @This();

pub const Mode = enum {
    input,
    output,
    duplex,
};

handle: *binding.PaStream,
mode: Mode,
channel_count: u16,
closed: bool = false,

pub fn make(handle: *binding.PaStream, mode: Mode, channel_count: u16) Self {
    return .{
        .handle = handle,
        .mode = mode,
        .channel_count = channel_count,
    };
}

pub fn deinit(self: *Self) error_mod.Error!void {
    try self.close();
}

pub fn close(self: *Self) error_mod.Error!void {
    if (self.closed) return;
    try error_mod.check(binding.Pa_CloseStream(self.handle));
    self.closed = true;
}

pub fn start(self: *Self) error_mod.Error!void {
    try error_mod.check(binding.Pa_StartStream(self.handle));
}

pub fn stop(self: *Self) error_mod.Error!void {
    try error_mod.check(binding.Pa_StopStream(self.handle));
}

pub fn abort(self: *Self) error_mod.Error!void {
    try error_mod.check(binding.Pa_AbortStream(self.handle));
}

pub fn isStopped(self: Self) error_mod.Error!bool {
    const code = binding.Pa_IsStreamStopped(self.handle);
    if (code == 0) return false;
    if (code == 1) return true;
    try error_mod.check(code);
    return false;
}

pub fn isActive(self: Self) error_mod.Error!bool {
    const code = binding.Pa_IsStreamActive(self.handle);
    if (code == 0) return false;
    if (code == 1) return true;
    try error_mod.check(code);
    return false;
}

pub fn info(self: Self) ?*const binding.PaStreamInfo {
    return binding.Pa_GetStreamInfo(self.handle);
}

pub fn read(self: *Self, buffer: []i16, frames: usize) error_mod.Error!void {
    if (self.mode == .output) return error_mod.Error.CanNotReadFromAnOutputOnlyStream;
    if (buffer.len < self.frameSampleCount(frames)) return error_mod.Error.BufferTooSmall;
    try error_mod.check(binding.Pa_ReadStream(self.handle, buffer.ptr, @intCast(frames)));
}

pub fn write(self: *Self, buffer: []const i16, frames: usize) error_mod.Error!void {
    if (self.mode == .input) return error_mod.Error.CanNotWriteToAnInputOnlyStream;
    if (buffer.len < self.frameSampleCount(frames)) return error_mod.Error.BufferTooSmall;
    try error_mod.check(binding.Pa_WriteStream(self.handle, buffer.ptr, @intCast(frames)));
}

pub fn readAvailable(self: Self) error_mod.Error!usize {
    return try error_mod.checkedAvailable(binding.Pa_GetStreamReadAvailable(self.handle));
}

pub fn writeAvailable(self: Self) error_mod.Error!usize {
    return try error_mod.checkedAvailable(binding.Pa_GetStreamWriteAvailable(self.handle));
}

pub fn frameSampleCount(self: Self, frames: usize) usize {
    return frames * self.channel_count;
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

            modeGuardsRejectWrongDirection() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            frameLengthChecksFollowChannelCount() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            deinitIsNoopWhenAlreadyClosed() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }

        fn modeGuardsRejectWrongDirection() !void {
            var input_stream = make(undefined, .input, 1);
            var output_stream = make(undefined, .output, 1);
            var read_buf = [_]i16{0};

            try grt.std.testing.expectError(
                error_mod.Error.CanNotWriteToAnInputOnlyStream,
                input_stream.write(&.{1}, 1),
            );
            try grt.std.testing.expectError(
                error_mod.Error.CanNotReadFromAnOutputOnlyStream,
                output_stream.read(read_buf[0..], 1),
            );
        }

        fn frameLengthChecksFollowChannelCount() !void {
            var duplex_stream = make(undefined, .duplex, 2);

            try grt.std.testing.expectEqual(@as(usize, 8), duplex_stream.frameSampleCount(4));
            try grt.std.testing.expectError(error_mod.Error.BufferTooSmall, duplex_stream.write(&.{ 1, 2, 3 }, 2));
        }

        fn deinitIsNoopWhenAlreadyClosed() !void {
            var stream = make(undefined, .input, 1);
            stream.closed = true;
            try stream.deinit();
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}

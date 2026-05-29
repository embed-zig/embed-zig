//! I2S frame/slot byte transport contract.
//!
//! Platform code owns peripheral setup, pins, DMA, and teardown. This wrapper
//! owns the I2S frame/slot buffer shape and exposes read/write views over full
//! slot byte slices. It does not interpret PCM sample formats.

const glib = @import("glib");

const I2s = @This();

pub const Error = error{
    BusError,
    InvalidFrameSize,
    InvalidLane,
    NotStarted,
    OutOfMemory,
    Timeout,
    Unexpected,
    Unsupported,
};

pub const Config = struct {
    /// Number of hardware slots carried by one I2S frame.
    slots_per_frame: usize,
    /// Size of one hardware slot in bytes.
    bytes_per_slot: usize,
    /// Number of full I2S frames held by each internal read/write buffer.
    buffer_frame_count: usize,

    pub fn frameSizeBytes(self: Config) usize {
        return self.slots_per_frame * self.bytes_per_slot;
    }

    pub fn bufferSizeBytes(self: Config) usize {
        return self.frameSizeBytes() * self.buffer_frame_count;
    }
};

pub const ReadView = struct {
    frames: usize,
    slots_per_frame: usize,
    bytes_per_slot: usize,
    buffer: []const u8,

    pub fn slot(self: ReadView, frame: usize, slot_index: usize) Error![]const u8 {
        if (frame >= self.frames) return error.InvalidFrameSize;
        if (slot_index >= self.slots_per_frame) return error.InvalidLane;

        const offset = self.slotOffset(frame, slot_index);
        return self.buffer[offset..][0..self.bytes_per_slot];
    }

    fn slotOffset(self: ReadView, frame: usize, slot_index: usize) usize {
        return frame * self.frameSizeBytes() + slot_index * self.bytes_per_slot;
    }

    fn frameSizeBytes(self: ReadView) usize {
        return self.slots_per_frame * self.bytes_per_slot;
    }
};

pub const WriteView = struct {
    frames: usize,
    slots_per_frame: usize,
    bytes_per_slot: usize,
    buffer: []u8,

    pub fn slot(self: WriteView, frame: usize, slot_index: usize) Error![]u8 {
        if (frame >= self.frames) return error.InvalidFrameSize;
        if (slot_index >= self.slots_per_frame) return error.InvalidLane;

        const offset = self.slotOffset(frame, slot_index);
        return self.buffer[offset..][0..self.bytes_per_slot];
    }

    fn slotOffset(self: WriteView, frame: usize, slot_index: usize) usize {
        return frame * self.frameSizeBytes() + slot_index * self.bytes_per_slot;
    }

    fn frameSizeBytes(self: WriteView) usize {
        return self.slots_per_frame * self.bytes_per_slot;
    }
};

pub const VTable = struct {
    write: *const fn (ptr: *anyopaque, data: []const u8) Error!usize,
    read: *const fn (ptr: *anyopaque, buf: []u8) Error!usize,
};

allocator: glib.std.mem.Allocator,
ptr: *anyopaque,
vtable: *const VTable,
config_: Config,
read_buffer: []u8,
write_buffer: []u8,
pending_write_frames: usize = 0,

pub fn init(allocator: glib.std.mem.Allocator, pointer: anytype, i2s_config: Config) Error!I2s {
    const Ptr = @TypeOf(pointer);
    const info = @typeInfo(Ptr);
    if (info != .pointer or info.pointer.size != .one) {
        @compileError("I2s.init expects a single-item pointer");
    }

    const Impl = info.pointer.child;
    comptime {
        _ = @as(*const fn (*Impl, []const u8) Error!usize, &Impl.write);
        _ = @as(*const fn (*Impl, []u8) Error!usize, &Impl.read);
    }

    try validateConfig(i2s_config);

    const read_storage = allocator.alloc(u8, i2s_config.bufferSizeBytes()) catch return error.OutOfMemory;
    errdefer allocator.free(read_storage);
    const write_storage = allocator.alloc(u8, i2s_config.bufferSizeBytes()) catch return error.OutOfMemory;
    errdefer allocator.free(write_storage);

    const gen = struct {
        fn writeFn(ptr: *anyopaque, data: []const u8) Error!usize {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.write(data);
        }

        fn readFn(ptr: *anyopaque, buf: []u8) Error!usize {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.read(buf);
        }

        const vtable = VTable{
            .write = writeFn,
            .read = readFn,
        };
    };

    return .{
        .allocator = allocator,
        .ptr = pointer,
        .vtable = &gen.vtable,
        .config_ = i2s_config,
        .read_buffer = read_storage,
        .write_buffer = write_storage,
    };
}

pub fn deinit(self: *I2s) void {
    if (self.read_buffer.len != 0) self.allocator.free(self.read_buffer);
    if (self.write_buffer.len != 0) self.allocator.free(self.write_buffer);
    self.* = undefined;
}

pub fn config(self: I2s) Config {
    return self.config_;
}

pub fn slotsPerFrame(self: I2s) usize {
    return self.config_.slots_per_frame;
}

pub fn bytesPerSlot(self: I2s) usize {
    return self.config_.bytes_per_slot;
}

pub fn bufferFrameCount(self: I2s) usize {
    return self.config_.buffer_frame_count;
}

pub fn frameSizeBytes(self: I2s) usize {
    return self.config_.frameSizeBytes();
}

pub fn bufferSizeBytes(self: I2s) usize {
    return self.config_.bufferSizeBytes();
}

pub fn read(self: *I2s) Error!ReadView {
    return self.readFrames(self.bufferFrameCount());
}

pub fn readFrames(self: *I2s, frame_count: usize) Error!ReadView {
    if (frame_count > self.bufferFrameCount()) return error.InvalidFrameSize;

    const bytes_to_read = frame_count * self.frameSizeBytes();
    const bytes_read = try self.vtable.read(self.ptr, self.read_buffer[0..bytes_to_read]);
    if (bytes_read > bytes_to_read) return error.Unexpected;
    if (bytes_read % self.frameSizeBytes() != 0) return error.InvalidFrameSize;

    const frames_read = bytes_read / self.frameSizeBytes();
    return .{
        .frames = frames_read,
        .slots_per_frame = self.slotsPerFrame(),
        .bytes_per_slot = self.bytesPerSlot(),
        .buffer = self.read_buffer[0..bytes_read],
    };
}

pub fn writeView(self: *I2s, frame_count: usize) Error!WriteView {
    if (frame_count > self.bufferFrameCount()) return error.InvalidFrameSize;

    const bytes_to_write = frame_count * self.frameSizeBytes();
    self.pending_write_frames = frame_count;
    @memset(self.write_buffer[0..bytes_to_write], 0);

    return .{
        .frames = frame_count,
        .slots_per_frame = self.slotsPerFrame(),
        .bytes_per_slot = self.bytesPerSlot(),
        .buffer = self.write_buffer[0..bytes_to_write],
    };
}

pub fn flush(self: *I2s) Error!usize {
    if (self.pending_write_frames == 0) return 0;

    const bytes_to_write = self.pending_write_frames * self.frameSizeBytes();
    const bytes_written = try self.vtable.write(self.ptr, self.write_buffer[0..bytes_to_write]);
    if (bytes_written > bytes_to_write) return error.Unexpected;
    if (bytes_written % self.frameSizeBytes() != 0) return error.InvalidFrameSize;

    self.pending_write_frames = 0;
    return bytes_written / self.frameSizeBytes();
}

fn validateConfig(i2s_config: Config) Error!void {
    if (i2s_config.slots_per_frame == 0) return error.InvalidFrameSize;
    if (i2s_config.bytes_per_slot == 0) return error.InvalidFrameSize;
    if (i2s_config.buffer_frame_count == 0) return error.InvalidFrameSize;
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn readReturnsSlotViews(allocator: glib.std.mem.Allocator) !void {
            const Fake = struct {
                pub fn write(_: *@This(), data: []const u8) Error!usize {
                    return data.len;
                }

                pub fn read(_: *@This(), buf: []u8) Error!usize {
                    for (buf, 0..) |*byte, index| byte.* = @intCast(index);
                    return buf.len;
                }
            };

            var fake = Fake{};
            var stream = try I2s.init(allocator, &fake, .{
                .slots_per_frame = 2,
                .bytes_per_slot = 2,
                .buffer_frame_count = 2,
            });
            defer stream.deinit();

            try grt.std.testing.expectEqual(@as(usize, 4), stream.frameSizeBytes());
            try grt.std.testing.expectEqual(@as(usize, 8), stream.bufferSizeBytes());

            const view = try stream.read();
            try grt.std.testing.expectEqual(@as(usize, 2), view.frames);
            try grt.std.testing.expectEqualSlices(u8, &.{ 0, 1 }, try view.slot(0, 0));
            try grt.std.testing.expectEqualSlices(u8, &.{ 2, 3 }, try view.slot(0, 1));
            try grt.std.testing.expectEqualSlices(u8, &.{ 4, 5 }, try view.slot(1, 0));
            try grt.std.testing.expectEqualSlices(u8, &.{ 6, 7 }, try view.slot(1, 1));
        }

        fn writeViewFlushesSlotBytes(allocator: glib.std.mem.Allocator) !void {
            const Fake = struct {
                writes: [8]u8 = [_]u8{0} ** 8,
                write_len: usize = 0,

                pub fn write(self: *@This(), data: []const u8) Error!usize {
                    @memcpy(self.writes[0..data.len], data);
                    self.write_len = data.len;
                    return data.len;
                }

                pub fn read(_: *@This(), buf: []u8) Error!usize {
                    return buf.len;
                }
            };

            var fake = Fake{};
            var stream = try I2s.init(allocator, &fake, .{
                .slots_per_frame = 2,
                .bytes_per_slot = 2,
                .buffer_frame_count = 2,
            });
            defer stream.deinit();

            const view = try stream.writeView(2);
            @memcpy(try view.slot(0, 0), &[_]u8{ 1, 2 });
            @memcpy(try view.slot(0, 1), &[_]u8{ 3, 4 });
            @memcpy(try view.slot(1, 0), &[_]u8{ 5, 6 });
            @memcpy(try view.slot(1, 1), &[_]u8{ 7, 8 });

            try grt.std.testing.expectEqual(@as(usize, 2), try stream.flush());
            try grt.std.testing.expectEqual(@as(usize, 8), fake.write_len);
            try grt.std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, fake.writes[0..8]);
            try grt.std.testing.expectEqual(@as(usize, 0), try stream.flush());
        }

        fn rejectsInvalidFramesAndSlots(allocator: glib.std.mem.Allocator) !void {
            const Fake = struct {
                pub fn write(_: *@This(), _: []const u8) Error!usize {
                    return 3;
                }

                pub fn read(_: *@This(), _: []u8) Error!usize {
                    return 3;
                }
            };

            var fake = Fake{};
            var stream = try I2s.init(allocator, &fake, .{
                .slots_per_frame = 2,
                .bytes_per_slot = 2,
                .buffer_frame_count = 1,
            });
            defer stream.deinit();

            try grt.std.testing.expectError(error.InvalidFrameSize, stream.read());

            const view = try stream.writeView(1);
            try grt.std.testing.expectError(error.InvalidFrameSize, view.slot(1, 0));
            try grt.std.testing.expectError(error.InvalidLane, view.slot(0, 2));
            try grt.std.testing.expectError(error.InvalidFrameSize, stream.writeView(2));
            try grt.std.testing.expectError(error.InvalidFrameSize, stream.flush());
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            TestCase.readReturnsSlotViews(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.writeViewFlushesSlotBytes(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.rejectsInvalidFramesAndSlots(allocator) catch |err| {
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

//! Uart — non-owning type-erased byte-oriented UART.
//!
//! This wrapper exposes the synchronous UART surface currently needed by
//! `lib/drivers`: byte-stream reads/writes, per-direction timeouts, and baud
//! reconfiguration.

const Uart = @This();
const testing_api = @import("testing");

ptr: *anyopaque,
vtable: *const VTable,

pub const Baud = enum(u32) {
    bps_9600 = 9600,
    bps_19200 = 19200,
    bps_38400 = 38400,
    bps_57600 = 57600,
    bps_115200 = 115200,
    bps_230400 = 230400,
    bps_460800 = 460800,
    bps_921600 = 921600,

    pub fn value(self: Baud) u32 {
        return @intFromEnum(self);
    }
};

pub const ReadError = error{
    EndOfStream,
    Overrun,
    Framing,
    Parity,
    TimedOut,
    Unexpected,
};

pub const WriteError = error{
    Overrun,
    TimedOut,
    Unexpected,
};

pub const BaudError = error{
    Busy,
    Unsupported,
    InvalidConfig,
    Unexpected,
};

pub const VTable = struct {
    read: *const fn (ptr: *anyopaque, buf: []u8) ReadError!usize,
    write: *const fn (ptr: *anyopaque, buf: []const u8) WriteError!usize,
    setReadTimeout: *const fn (ptr: *anyopaque, ms: ?u32) void,
    setWriteTimeout: *const fn (ptr: *anyopaque, ms: ?u32) void,
    setBaud: *const fn (ptr: *anyopaque, baud: Baud) BaudError!void,
};

pub fn read(self: Uart, buf: []u8) ReadError!usize {
    return self.vtable.read(self.ptr, buf);
}

pub fn write(self: Uart, buf: []const u8) WriteError!usize {
    return self.vtable.write(self.ptr, buf);
}

pub fn setReadTimeout(self: Uart, ms: ?u32) void {
    self.vtable.setReadTimeout(self.ptr, ms);
}

pub fn setWriteTimeout(self: Uart, ms: ?u32) void {
    self.vtable.setWriteTimeout(self.ptr, ms);
}

pub fn setBaud(self: Uart, baud: Baud) BaudError!void {
    return self.vtable.setBaud(self.ptr, baud);
}

pub fn init(pointer: anytype) Uart {
    const Ptr = @TypeOf(pointer);
    const info = @typeInfo(Ptr);
    if (info != .pointer or info.pointer.size != .one)
        @compileError("Uart.init expects a single-item pointer");

    const Impl = info.pointer.child;

    const gen = struct {
        fn readFn(ptr: *anyopaque, buf: []u8) ReadError!usize {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.read(buf);
        }

        fn writeFn(ptr: *anyopaque, buf: []const u8) WriteError!usize {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.write(buf);
        }

        fn setReadTimeoutFn(ptr: *anyopaque, ms: ?u32) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.setReadTimeout(ms);
        }

        fn setWriteTimeoutFn(ptr: *anyopaque, ms: ?u32) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.setWriteTimeout(ms);
        }

        fn setBaudFn(ptr: *anyopaque, baud: Baud) BaudError!void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.setBaud(baud);
        }

        const vtable = VTable{
            .read = readFn,
            .write = writeFn,
            .setReadTimeout = setReadTimeoutFn,
            .setWriteTimeout = setWriteTimeoutFn,
            .setBaud = setBaudFn,
        };
    };

    return .{
        .ptr = pointer,
        .vtable = &gen.vtable,
    };
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const TestCase = struct {
        fn dispatchesReadWriteTimeoutsAndBaud() !void {
            const Fake = struct {
                read_fill: [4]u8 = .{ 0x41, 0x54, 0x0d, 0x0a },
                last_write: [8]u8 = [_]u8{0} ** 8,
                last_write_len: usize = 0,
                read_timeout_ms: ?u32 = null,
                write_timeout_ms: ?u32 = null,
                baud: Baud = .bps_115200,

                fn read(self: *@This(), buf: []u8) ReadError!usize {
                    const count = @min(buf.len, self.read_fill.len);
                    @memcpy(buf[0..count], self.read_fill[0..count]);
                    return count;
                }

                fn write(self: *@This(), buf: []const u8) WriteError!usize {
                    self.last_write_len = buf.len;
                    @memcpy(self.last_write[0..buf.len], buf);
                    return buf.len;
                }

                fn setReadTimeout(self: *@This(), ms: ?u32) void {
                    self.read_timeout_ms = ms;
                }

                fn setWriteTimeout(self: *@This(), ms: ?u32) void {
                    self.write_timeout_ms = ms;
                }

                fn setBaud(self: *@This(), baud: Baud) BaudError!void {
                    self.baud = baud;
                }
            };

            var fake = Fake{};
            const uart = Uart.init(&fake);

            var buf: [3]u8 = undefined;
            try lib.testing.expectEqual(@as(usize, 3), try uart.read(&buf));
            try lib.testing.expectEqualSlices(u8, &.{ 0x41, 0x54, 0x0d }, &buf);

            try lib.testing.expectEqual(@as(usize, 4), try uart.write("AT\r\n"));
            try lib.testing.expectEqual(@as(usize, 4), fake.last_write_len);
            try lib.testing.expectEqualSlices(u8, "AT\r\n", fake.last_write[0..4]);

            uart.setReadTimeout(100);
            uart.setWriteTimeout(200);
            try lib.testing.expectEqual(@as(?u32, 100), fake.read_timeout_ms);
            try lib.testing.expectEqual(@as(?u32, 200), fake.write_timeout_ms);

            try uart.setBaud(.bps_921600);
            try lib.testing.expectEqual(Baud.bps_921600, fake.baud);
        }

        fn propagatesBackendErrors() !void {
            const Fake = struct {
                fail_read: bool = false,
                fail_write: bool = false,
                fail_baud: bool = false,

                fn read(self: *@This(), _: []u8) ReadError!usize {
                    if (self.fail_read) return error.TimedOut;
                    return 0;
                }

                fn write(self: *@This(), buf: []const u8) WriteError!usize {
                    if (self.fail_write) return error.Overrun;
                    return buf.len;
                }

                fn setReadTimeout(_: *@This(), _: ?u32) void {}

                fn setWriteTimeout(_: *@This(), _: ?u32) void {}

                fn setBaud(self: *@This(), _: Baud) BaudError!void {
                    if (self.fail_baud) return error.Unsupported;
                }
            };

            var fake = Fake{ .fail_read = true };
            const uart = Uart.init(&fake);

            var buf: [1]u8 = undefined;
            try lib.testing.expectError(error.TimedOut, uart.read(&buf));

            fake.fail_read = false;
            fake.fail_write = true;
            try lib.testing.expectError(error.Overrun, uart.write("A"));

            fake.fail_write = false;
            fake.fail_baud = true;
            try lib.testing.expectError(error.Unsupported, uart.setBaud(.bps_460800));
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.dispatchesReadWriteTimeoutsAndBaud() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.propagatesBackendErrors() catch |err| {
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

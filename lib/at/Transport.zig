//! Transport — type-erased byte stream for AT command sessions.
//!
//! VTable-based runtime dispatch. Any concrete backend with `read` / `write`,
//! `flushRx`, `reset`, `deinit`, and read/write deadlines can be wrapped here.
//!
//! Extends `lib/bt/Transport.zig` with **`flushRx`**: discard pending inbound
//! bytes in the driver (UART/USB) without tearing the link down. Use `reset`
//! for a stronger controller-level reset when the backend distinguishes the two.

const root = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    write: *const fn (ptr: *anyopaque, buf: []const u8) WriteError!usize,
    read: *const fn (ptr: *anyopaque, buf: []u8) ReadError!usize,
    /// Drop buffered RX data (hardware FIFO / driver queue); link stays up.
    flushRx: *const fn (ptr: *anyopaque) void,
    reset: *const fn (ptr: *anyopaque) void,
    deinit: *const fn (ptr: *anyopaque) void,
    setReadDeadline: *const fn (ptr: *anyopaque, deadline_ns: ?i64) void,
    setWriteDeadline: *const fn (ptr: *anyopaque, deadline_ns: ?i64) void,
};

pub const WriteError = error{
    Timeout,
    HwError,
    Unexpected,
};

pub const ReadError = error{
    Timeout,
    HwError,
    Unexpected,
};

pub const SendError = WriteError;
pub const RecvError = ReadError;

pub fn write(self: root, buf: []const u8) WriteError!usize {
    return self.vtable.write(self.ptr, buf);
}

pub fn read(self: root, buf: []u8) ReadError!usize {
    return self.vtable.read(self.ptr, buf);
}

pub fn flushRx(self: root) void {
    self.vtable.flushRx(self.ptr);
}

pub fn reset(self: root) void {
    self.vtable.reset(self.ptr);
}

pub fn setReadDeadline(self: root, deadline_ns: ?i64) void {
    self.vtable.setReadDeadline(self.ptr, deadline_ns);
}

pub fn setWriteDeadline(self: root, deadline_ns: ?i64) void {
    self.vtable.setWriteDeadline(self.ptr, deadline_ns);
}

pub fn deinit(self: root) void {
    self.vtable.deinit(self.ptr);
}

pub fn init(pointer: anytype) root {
    const Ptr = @TypeOf(pointer);
    const info = @typeInfo(Ptr);
    if (info != .pointer or info.pointer.size != .one)
        @compileError("Transport.init expects a single-item pointer");

    const Impl = info.pointer.child;

    const gen = struct {
        fn writeFn(ptr: *anyopaque, buf: []const u8) WriteError!usize {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.write(buf);
        }
        fn readFn(ptr: *anyopaque, buf: []u8) ReadError!usize {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.read(buf);
        }
        fn flushRxFn(ptr: *anyopaque) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.flushRx();
        }
        fn resetFn(ptr: *anyopaque) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.reset();
        }
        fn deinitFn(ptr: *anyopaque) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.deinit();
        }
        fn setReadDeadlineFn(ptr: *anyopaque, deadline_ns: ?i64) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.setReadDeadline(deadline_ns);
        }
        fn setWriteDeadlineFn(ptr: *anyopaque, deadline_ns: ?i64) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.setWriteDeadline(deadline_ns);
        }

        const vtable = VTable{
            .write = writeFn,
            .read = readFn,
            .flushRx = flushRxFn,
            .reset = resetFn,
            .deinit = deinitFn,
            .setReadDeadline = setReadDeadlineFn,
            .setWriteDeadline = setWriteDeadlineFn,
        };
    };

    return .{
        .ptr = pointer,
        .vtable = &gen.vtable,
    };
}

const testing_api = @import("testing");

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const TestCase = struct {
        fn testInitForwards() !void {
            const std = @import("std");
            const testing = std.testing;

            const Impl = struct {
                read_deadline: ?i64 = null,
                write_deadline: ?i64 = null,
                out: []const u8 = "OK\r\n",
                out_pos: usize = 0,
                written: [16]u8 = undefined,
                written_len: usize = 0,
                flush_rx_hits: u32 = 0,
                reset_hits: u32 = 0,
                deinit_hits: u32 = 0,

                fn write(self: *@This(), buf: []const u8) WriteError!usize {
                    if (self.written_len + buf.len > self.written.len) return error.Unexpected;
                    @memcpy(self.written[self.written_len..][0..buf.len], buf);
                    self.written_len += buf.len;
                    return buf.len;
                }

                fn read(self: *@This(), buf: []u8) ReadError!usize {
                    if (self.out_pos >= self.out.len) return 0;
                    const n = @min(buf.len, self.out.len - self.out_pos);
                    @memcpy(buf[0..n], self.out[self.out_pos..][0..n]);
                    self.out_pos += n;
                    return n;
                }

                fn flushRx(self: *@This()) void {
                    self.flush_rx_hits += 1;
                    self.out_pos = self.out.len;
                }

                fn reset(self: *@This()) void {
                    self.reset_hits += 1;
                }

                fn deinit(self: *@This()) void {
                    self.deinit_hits += 1;
                }

                fn setReadDeadline(self: *@This(), deadline_ns: ?i64) void {
                    self.read_deadline = deadline_ns;
                }

                fn setWriteDeadline(self: *@This(), deadline_ns: ?i64) void {
                    self.write_deadline = deadline_ns;
                }
            };

            var impl = Impl{};
            const transport = init(&impl);

            transport.setReadDeadline(1_000_000);
            try testing.expectEqual(@as(?i64, 1_000_000), impl.read_deadline);
            transport.setWriteDeadline(null);
            try testing.expectEqual(@as(?i64, null), impl.write_deadline);

            const w = try transport.write("AT\r\n");
            try testing.expectEqual(@as(usize, 4), w);
            try testing.expectEqualStrings("AT\r\n", impl.written[0..impl.written_len]);

            var rbuf: [8]u8 = undefined;
            const r = try transport.read(&rbuf);
            try testing.expectEqual(@as(usize, 4), r);
            try testing.expectEqualStrings("OK\r\n", rbuf[0..r]);

            impl.out_pos = 0;
            _ = try transport.read(&rbuf);
            transport.flushRx();
            try testing.expectEqual(@as(u32, 1), impl.flush_rx_hits);
            try testing.expect(impl.out_pos >= impl.out.len);

            transport.reset();
            try testing.expectEqual(@as(u32, 1), impl.reset_hits);

            transport.deinit();
            try testing.expectEqual(@as(u32, 1), impl.deinit_hits);
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

            TestCase.testInitForwards() catch |err| {
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

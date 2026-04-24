//! UdpConn — constructs a Conn or PacketConn over a runtime UDP socket.
//!
//! Returns Conn / PacketConn directly. The internal state is heap-allocated
//! and freed on deinit().

const Conn = @import("Conn.zig");
const PacketConn = @import("PacketConn.zig");
const netip = @import("netip.zig");
const runtime_mod = @import("runtime.zig");

pub fn UdpConn(comptime lib: type, comptime net: type) type {
    const Allocator = lib.mem.Allocator;
    const AddrPort = netip.AddrPort;
    const Mutex = lib.Thread.Mutex;
    const Runtime = net.Runtime;
    const UdpSocket = Runtime.Udp;

    return struct {
        socket: UdpSocket,
        allocator: Allocator,
        closed: u8 = 0,
        read_mu: Mutex = .{},
        write_mu: Mutex = .{},
        read_waiting: bool = false,
        write_waiting: bool = false,
        read_timeout_ms: ?u32 = null,
        write_timeout_ms: ?u32 = null,
        read_state_gen: u64 = 0,
        write_state_gen: u64 = 0,

        const Self = @This();
        const WaitState = struct {
            config_gen: ?u64 = null,
            deadline_ms: ?i64 = null,
        };

        pub const BatchItem = struct {
            buf: []u8,
            len: usize = 0,
            addr: AddrPort = .{},
        };

        pub const BatchReadError = PacketConn.ReadFromError || error{
            InvalidBatchItem,
        };

        pub const BatchWriteError = PacketConn.WriteToError || error{
            InvalidBatchItem,
            ShortWrite,
        };

        pub const LocalAddrError = runtime_mod.SocketError;

        pub fn read(self: *Self, buf: []u8) Conn.ReadError!usize {
            if (self.isClosed()) return error.EndOfStream;
            if (buf.len == 0) return 0;
            var wait_state = WaitState{};

            while (true) {
                self.ensureReadActive(&wait_state) catch |err| switch (err) {
                    error.Closed => return error.EndOfStream,
                    error.TimedOut => return error.TimedOut,
                };
                const n = self.socket.recv(buf) catch |err| switch (err) {
                    error.WouldBlock => {
                        try self.waitReadableConn(&wait_state);
                        continue;
                    },
                    error.Closed => return error.EndOfStream,
                    error.ConnectionRefused => return error.ConnectionRefused,
                    error.ConnectionReset => return error.ConnectionReset,
                    error.TimedOut => return error.TimedOut,
                    else => return error.Unexpected,
                };
                return n;
            }
        }

        pub fn write(self: *Self, buf: []const u8) Conn.WriteError!usize {
            if (self.isClosed()) return error.BrokenPipe;
            var wait_state = WaitState{};

            while (true) {
                self.ensureWriteActive(&wait_state) catch |err| switch (err) {
                    error.Closed => return error.BrokenPipe,
                    error.TimedOut => return error.TimedOut,
                };
                const n = self.socket.send(buf) catch |err| switch (err) {
                    error.WouldBlock => {
                        try self.waitWritableConn(&wait_state);
                        continue;
                    },
                    error.Closed => return error.BrokenPipe,
                    error.ConnectionRefused => return error.ConnectionRefused,
                    error.ConnectionReset => return error.ConnectionReset,
                    error.BrokenPipe => return error.BrokenPipe,
                    error.TimedOut => return error.TimedOut,
                    else => return error.Unexpected,
                };
                return n;
            }
        }

        pub fn readFrom(self: *Self, buf: []u8) PacketConn.ReadFromError!PacketConn.ReadFromResult {
            if (self.isClosed()) return error.Closed;
            if (buf.len == 0) return .{
                .bytes_read = 0,
                .addr = .{},
            };
            var wait_state = WaitState{};

            var remote: AddrPort = undefined;
            const bytes_read = while (true) {
                self.ensureReadActive(&wait_state) catch |err| switch (err) {
                    error.Closed => return error.Closed,
                    error.TimedOut => return error.TimedOut,
                };
                const n = self.socket.recvFrom(buf, &remote) catch |err| switch (err) {
                    error.WouldBlock => {
                        try self.waitReadable(&wait_state);
                        continue;
                    },
                    error.Closed => return error.Closed,
                    error.ConnectionRefused => return error.ConnectionRefused,
                    error.ConnectionReset => return error.ConnectionReset,
                    error.TimedOut => return error.TimedOut,
                    else => return error.Unexpected,
                };
                break n;
            };

            return .{
                .bytes_read = bytes_read,
                .addr = remote,
            };
        }

        pub fn writeTo(self: *Self, buf: []const u8, addr: AddrPort) PacketConn.WriteToError!usize {
            if (self.isClosed()) return error.Closed;
            var wait_state = WaitState{};

            while (true) {
                self.ensureWriteActive(&wait_state) catch |err| switch (err) {
                    error.Closed => return error.Closed,
                    error.TimedOut => return error.TimedOut,
                };
                const n = self.socket.sendTo(buf, addr) catch |err| switch (err) {
                    error.WouldBlock => {
                        try self.waitWritable(&wait_state);
                        continue;
                    },
                    error.Closed => return error.Closed,
                    error.MessageTooLong => return error.MessageTooLong,
                    error.NetworkUnreachable => return error.NetworkUnreachable,
                    error.AccessDenied => return error.AccessDenied,
                    error.TimedOut => return error.TimedOut,
                    else => return error.Unexpected,
                };
                return n;
            }
        }

        // Returns the number of datagrams transferred. A short return means the batch
        // made partial progress and the caller should only trust slots 0..count.
        pub fn recvBatch(self: *Self, batch: []BatchItem, timeout_ms: ?u32) BatchReadError!usize {
            if (self.isClosed()) return error.Closed;
            if (batch.len == 0) return 0;
            for (batch) |item| {
                if (item.buf.len == 0) return error.InvalidBatchItem;
            }

            const saved_timeout = self.currentReadTimeout();
            defer self.setReadTimeout(saved_timeout);

            const deadline_ms = batchDeadline(timeout_ms orelse saved_timeout);
            var received: usize = 0;
            while (received < batch.len) : (received += 1) {
                self.setReadTimeout(remainingTimeoutMs(deadline_ms));

                const result = self.readFrom(batch[received].buf) catch |err| {
                    if (received != 0) return received;
                    return err;
                };

                batch[received].len = result.bytes_read;
                batch[received].addr = result.addr;
            }

            return received;
        }

        pub fn sendBatch(self: *Self, batch: []const BatchItem) BatchWriteError!usize {
            return self.sendBatchWithTimeout(batch, self.currentWriteTimeout());
        }

        // Returns the number of datagrams transferred. A short return means the batch
        // made partial progress and the caller should only retry the remaining suffix.
        pub fn sendBatchWithTimeout(self: *Self, batch: []const BatchItem, timeout_ms: ?u32) BatchWriteError!usize {
            if (self.isClosed()) return error.Closed;
            if (batch.len == 0) return 0;
            for (batch) |item| {
                if (item.len > item.buf.len) return error.InvalidBatchItem;
                if (!item.addr.isValid()) return error.InvalidBatchItem;
            }

            const saved_timeout = self.currentWriteTimeout();
            defer self.setWriteTimeout(saved_timeout);

            const deadline_ms = batchDeadline(timeout_ms orelse saved_timeout);
            var sent: usize = 0;
            while (sent < batch.len) : (sent += 1) {
                self.setWriteTimeout(remainingTimeoutMs(deadline_ms));

                const written = self.writeTo(
                    batch[sent].buf[0..batch[sent].len],
                    batch[sent].addr,
                ) catch |err| {
                    if (sent != 0) return sent;
                    return err;
                };

                if (written != batch[sent].len) {
                    if (sent != 0) return sent;
                    return error.ShortWrite;
                }
            }

            return sent;
        }

        pub fn localAddr(self: *Self) LocalAddrError!AddrPort {
            if (self.isClosed()) return error.Closed;
            return self.socket.localAddr();
        }

        pub fn close(self: *Self) void {
            if (self.markClosed()) return;
            self.socket.signal(.read_interrupt);
            self.socket.signal(.write_interrupt);
            self.socket.close();
        }

        pub fn deinit(self: *Self) void {
            self.close();
            self.socket.deinit();
            const a = self.allocator;
            a.destroy(self);
        }

        pub fn setReadTimeout(self: *Self, ms: ?u32) void {
            if (self.isClosed()) return;
            var should_signal = false;
            self.read_mu.lock();
            if (!self.isClosed()) {
                self.read_timeout_ms = ms;
                self.read_state_gen +%= 1;
                should_signal = self.read_waiting;
            }
            self.read_mu.unlock();
            if (should_signal) self.socket.signal(.read_interrupt);
        }

        pub fn setWriteTimeout(self: *Self, ms: ?u32) void {
            if (self.isClosed()) return;
            var should_signal = false;
            self.write_mu.lock();
            if (!self.isClosed()) {
                self.write_timeout_ms = ms;
                self.write_state_gen +%= 1;
                should_signal = self.write_waiting;
            }
            self.write_mu.unlock();
            if (should_signal) self.socket.signal(.write_interrupt);
        }

        pub fn boundPort(self: *Self) !u16 {
            const addr = try self.localAddr();
            if (!addr.addr().is4()) return error.AddressFamilyMismatch;
            return addr.port();
        }

        pub fn boundPort6(self: *Self) !u16 {
            const addr = try self.localAddr();
            if (!addr.addr().is6()) return error.AddressFamilyMismatch;
            return addr.port();
        }

        fn timeoutToDeadline(ms: ?u32) ?i64 {
            const timeout_ms = ms orelse return null;
            return lib.time.milliTimestamp() + timeout_ms;
        }

        fn batchDeadline(timeout_ms: ?u32) ?i64 {
            const ms = timeout_ms orelse return null;
            return lib.time.milliTimestamp() + @as(i64, ms);
        }

        fn remainingTimeoutMs(deadline_ms: ?i64) ?u32 {
            const deadline = deadline_ms orelse return null;
            const now = lib.time.milliTimestamp();
            if (deadline <= now) return 0;
            return @intCast(deadline - now);
        }

        fn currentReadTimeout(self: *Self) ?u32 {
            self.read_mu.lock();
            defer self.read_mu.unlock();
            return self.read_timeout_ms;
        }

        fn currentWriteTimeout(self: *Self) ?u32 {
            self.write_mu.lock();
            defer self.write_mu.unlock();
            return self.write_timeout_ms;
        }

        pub fn initFromSocket(allocator: Allocator, socket: UdpSocket) Allocator.Error!Conn {
            const self = try allocator.create(Self);
            self.* = .{
                .socket = socket,
                .allocator = allocator,
            };
            return Conn.init(self);
        }

        pub fn initPacketFromSocket(allocator: Allocator, socket: UdpSocket) Allocator.Error!PacketConn {
            const self = try allocator.create(Self);
            self.* = .{
                .socket = socket,
                .allocator = allocator,
            };
            return PacketConn.init(self);
        }

        fn waitReadableConn(self: *Self, wait_state: *WaitState) Conn.ReadError!void {
            while (true) {
                if (self.isClosed()) return error.EndOfStream;
                const poll_result = blk: {
                    const timeout_ms = self.beginReadWait(wait_state) catch |err| switch (err) {
                        error.Closed => return error.EndOfStream,
                        error.TimedOut => return error.TimedOut,
                    };
                    defer self.endReadWait();
                    break :blk self.socket.poll(.{
                        .read = true,
                        .failed = true,
                        .hup = true,
                        .read_interrupt = true,
                    }, timeout_ms);
                };
                _ = poll_result catch |err| switch (err) {
                    error.Closed => return error.EndOfStream,
                    error.TimedOut => {
                        if (self.readWaitExpired(wait_state)) return error.TimedOut;
                        continue;
                    },
                    else => return error.Unexpected,
                };
                return;
            }
        }

        fn waitWritableConn(self: *Self, wait_state: *WaitState) Conn.WriteError!void {
            while (true) {
                if (self.isClosed()) return error.BrokenPipe;
                const poll_result = blk: {
                    const timeout_ms = self.beginWriteWait(wait_state) catch |err| switch (err) {
                        error.Closed => return error.BrokenPipe,
                        error.TimedOut => return error.TimedOut,
                    };
                    defer self.endWriteWait();
                    break :blk self.socket.poll(.{
                        .write = true,
                        .failed = true,
                        .hup = true,
                        .write_interrupt = true,
                    }, timeout_ms);
                };
                _ = poll_result catch |err| switch (err) {
                    error.Closed => return error.BrokenPipe,
                    error.TimedOut => {
                        if (self.writeWaitExpired(wait_state)) return error.TimedOut;
                        continue;
                    },
                    else => return error.Unexpected,
                };
                return;
            }
        }

        fn waitReadable(self: *Self, wait_state: *WaitState) PacketConn.ReadFromError!void {
            while (true) {
                if (self.isClosed()) return error.Closed;
                const poll_result = blk: {
                    const timeout_ms = self.beginReadWait(wait_state) catch |err| switch (err) {
                        error.Closed => return error.Closed,
                        error.TimedOut => return error.TimedOut,
                    };
                    defer self.endReadWait();
                    break :blk self.socket.poll(.{
                        .read = true,
                        .failed = true,
                        .hup = true,
                        .read_interrupt = true,
                    }, timeout_ms);
                };
                _ = poll_result catch |err| switch (err) {
                    error.Closed => return error.Closed,
                    error.TimedOut => {
                        if (self.readWaitExpired(wait_state)) return error.TimedOut;
                        continue;
                    },
                    else => return error.Unexpected,
                };
                return;
            }
        }

        fn waitWritable(self: *Self, wait_state: *WaitState) PacketConn.WriteToError!void {
            while (true) {
                if (self.isClosed()) return error.Closed;
                const poll_result = blk: {
                    const timeout_ms = self.beginWriteWait(wait_state) catch |err| switch (err) {
                        error.Closed => return error.Closed,
                        error.TimedOut => return error.TimedOut,
                    };
                    defer self.endWriteWait();
                    break :blk self.socket.poll(.{
                        .write = true,
                        .failed = true,
                        .hup = true,
                        .write_interrupt = true,
                    }, timeout_ms);
                };
                _ = poll_result catch |err| switch (err) {
                    error.Closed => return error.Closed,
                    error.TimedOut => {
                        if (self.writeWaitExpired(wait_state)) return error.TimedOut;
                        continue;
                    },
                    else => return error.Unexpected,
                };
                return;
            }
        }

        fn remainingPollTimeout(deadline_ms: ?i64) ?u32 {
            const deadline = deadline_ms orelse return null;
            const now = lib.time.milliTimestamp();
            if (deadline <= now) return 0;
            return @intCast(deadline - now);
        }

        fn waitExpired(deadline_ms: ?i64) bool {
            const deadline = deadline_ms orelse return false;
            return deadline <= lib.time.milliTimestamp();
        }

        fn ensureReadActive(self: *Self, wait_state: *WaitState) error{ Closed, TimedOut }!void {
            self.read_mu.lock();
            defer self.read_mu.unlock();

            if (self.isClosed()) return error.Closed;
            self.syncReadWaitStateLocked(wait_state);
            if (waitExpired(wait_state.deadline_ms)) return error.TimedOut;
        }

        fn ensureWriteActive(self: *Self, wait_state: *WaitState) error{ Closed, TimedOut }!void {
            self.write_mu.lock();
            defer self.write_mu.unlock();

            if (self.isClosed()) return error.Closed;
            self.syncWriteWaitStateLocked(wait_state);
            if (waitExpired(wait_state.deadline_ms)) return error.TimedOut;
        }

        fn beginReadWait(self: *Self, wait_state: *WaitState) error{ Closed, TimedOut }!?u32 {
            self.read_mu.lock();
            defer self.read_mu.unlock();

            if (self.isClosed()) return error.Closed;
            self.syncReadWaitStateLocked(wait_state);
            if (waitExpired(wait_state.deadline_ms)) return error.TimedOut;
            self.read_waiting = true;
            return remainingPollTimeout(wait_state.deadline_ms);
        }

        fn beginWriteWait(self: *Self, wait_state: *WaitState) error{ Closed, TimedOut }!?u32 {
            self.write_mu.lock();
            defer self.write_mu.unlock();

            if (self.isClosed()) return error.Closed;
            self.syncWriteWaitStateLocked(wait_state);
            if (waitExpired(wait_state.deadline_ms)) return error.TimedOut;
            self.write_waiting = true;
            return remainingPollTimeout(wait_state.deadline_ms);
        }

        fn endReadWait(self: *Self) void {
            self.read_mu.lock();
            defer self.read_mu.unlock();
            self.read_waiting = false;
        }

        fn endWriteWait(self: *Self) void {
            self.write_mu.lock();
            defer self.write_mu.unlock();
            self.write_waiting = false;
        }

        fn readWaitExpired(self: *Self, wait_state: *WaitState) bool {
            self.read_mu.lock();
            defer self.read_mu.unlock();

            self.syncReadWaitStateLocked(wait_state);
            return waitExpired(wait_state.deadline_ms);
        }

        fn writeWaitExpired(self: *Self, wait_state: *WaitState) bool {
            self.write_mu.lock();
            defer self.write_mu.unlock();

            self.syncWriteWaitStateLocked(wait_state);
            return waitExpired(wait_state.deadline_ms);
        }

        fn syncReadWaitStateLocked(self: *Self, wait_state: *WaitState) void {
            if (wait_state.config_gen != self.read_state_gen) {
                wait_state.config_gen = self.read_state_gen;
                wait_state.deadline_ms = timeoutToDeadline(self.read_timeout_ms);
            }
        }

        fn syncWriteWaitStateLocked(self: *Self, wait_state: *WaitState) void {
            if (wait_state.config_gen != self.write_state_gen) {
                wait_state.config_gen = self.write_state_gen;
                wait_state.deadline_ms = timeoutToDeadline(self.write_timeout_ms);
            }
        }

        fn isClosed(self: *const Self) bool {
            return @atomicLoad(u8, &self.closed, .acquire) != 0;
        }

        fn markClosed(self: *Self) bool {
            return @atomicRmw(u8, &self.closed, .Xchg, 1, .acq_rel) != 0;
        }
    };
}

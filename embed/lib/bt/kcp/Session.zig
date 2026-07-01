const glib = @import("glib");

const Config = @import("Config.zig");

pub fn Session(comptime grt: type, comptime kcp: type) type {
    const InputChannel = grt.sync.Channel(Packet);
    const WriteChannel = grt.sync.Channel(Packet);
    const RecvChannel = grt.sync.Channel(Packet);
    const AtomicBool = grt.std.atomic.Value(bool);

    return struct {
        const Self = @This();
        const log = grt.std.log.scoped(.bt_kcp);

        pub const OutputFn = *const fn (ctx: ?*anyopaque, data: []const u8) anyerror!void;
        pub const Error = error{
            Closed,
            TooLarge,
            InvalidMtu,
            KcpCreateFailed,
            KcpConfigureFailed,
            KcpInputFailed,
            KcpSendFailed,
            KcpRecvFailed,
            OutputFailed,
            Unexpected,
        };

        allocator: glib.std.mem.Allocator,
        config: Config,
        output_ctx: ?*anyopaque,
        output_fn: OutputFn,
        inst: *kcp.Kcp,
        input_ch: InputChannel,
        write_ch: WriteChannel,
        recv_ch: RecvChannel,
        closing: AtomicBool = AtomicBool.init(false),
        worker: ?grt.task.Handle = null,
        last_output_error: ?anyerror = null,
        output_packets: u64 = 0,
        output_bytes: u64 = 0,
        input_packets: u64 = 0,
        input_errors: u64 = 0,
        recv_bytes: u64 = 0,
        pending_recv: ?Packet = null,
        read_pending: ?Packet = null,
        read_offset: usize = 0,

        pub fn init(
            allocator: glib.std.mem.Allocator,
            config: Config,
            output_ctx: ?*anyopaque,
            output_fn: OutputFn,
        ) !*Self {
            var self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            var input_ch = try InputChannel.make(allocator, config.channel_capacity);
            errdefer input_ch.deinit();
            var write_ch = try WriteChannel.make(allocator, config.channel_capacity);
            errdefer write_ch.deinit();
            var recv_ch = try RecvChannel.make(allocator, config.channel_capacity);
            errdefer recv_ch.deinit();

            self.* = .{
                .allocator = allocator,
                .config = config,
                .output_ctx = output_ctx,
                .output_fn = output_fn,
                .inst = undefined,
                .input_ch = input_ch,
                .write_ch = write_ch,
                .recv_ch = recv_ch,
            };

            const inst = kcp.create(config.conv, self) orelse return error.KcpCreateFailed;
            errdefer kcp.release(inst);
            self.inst = inst;
            kcp.setOutput(inst, outputCallback);
            if (config.kcpMtu() < Config.MIN_KCP_MTU) return error.InvalidMtu;
            if (kcp.setMtu(inst, @intCast(config.kcpMtu())) != 0) return error.InvalidMtu;
            if (kcp.wndsize(inst, @intCast(config.send_window), @intCast(config.recv_window)) != 0) return error.KcpConfigureFailed;
            if (kcp.nodelay(
                inst,
                @intCast(config.nodelay),
                @intCast(config.interval_ms),
                @intCast(config.resend),
                @intCast(config.no_congestion_control),
            ) != 0) return error.KcpConfigureFailed;

            self.worker = try grt.task.go(
                "bt/kcp/stream",
                config.task_options,
                glib.task.Routine.init(self, workerMain),
            );
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.close();
            if (self.worker) |worker| {
                worker.join();
                self.worker = null;
            }
            kcp.release(self.inst);
            self.input_ch.deinit();
            self.write_ch.deinit();
            self.recv_ch.deinit();
            const allocator = self.allocator;
            self.* = undefined;
            allocator.destroy(self);
        }

        pub fn close(self: *Self) void {
            if (self.closing.swap(true, .acq_rel)) return;
            self.input_ch.close();
            self.write_ch.close();
            self.recv_ch.close();
        }

        pub fn input(self: *Self, data: []const u8) Error!void {
            try self.sendPacket(&self.input_ch, data);
        }

        pub fn write(self: *Self, data: []const u8) Error!void {
            var offset: usize = 0;
            const chunk_len = self.config.maxWriteChunkLen();
            while (offset < data.len) {
                const end = @min(data.len, offset + chunk_len);
                try self.sendPacket(&self.write_ch, data[offset..end]);
                offset = end;
            }
        }

        pub fn writeTimeout(self: *Self, data: []const u8, timeout: glib.time.duration.Duration) Error!bool {
            var offset: usize = 0;
            const chunk_len = self.config.maxWriteChunkLen();
            while (offset < data.len) {
                const end = @min(data.len, offset + chunk_len);
                if (!try self.sendPacketTimeout(&self.write_ch, data[offset..end], timeout)) return false;
                offset = end;
            }
            return true;
        }

        pub fn read(self: *Self, out: []u8) Error!usize {
            if (out.len == 0) return 0;
            if (self.readPending(out)) |n| return n;
            const result = self.recv_ch.recv() catch return error.Closed;
            if (!result.ok) return error.Closed;
            return self.copyReadPacket(result.value, out);
        }

        pub fn recvTimeout(self: *Self, out: []u8, timeout: glib.time.duration.Duration) Error!?usize {
            if (out.len == 0) return 0;
            if (self.readPending(out)) |n| return n;
            const result = self.recv_ch.recvTimeout(timeout) catch |err| switch (@as(anyerror, err)) {
                error.Timeout => return null,
                error.Closed => return error.Closed,
                else => return error.Unexpected,
            };
            if (!result.ok) return error.Closed;
            return self.copyReadPacket(result.value, out);
        }

        pub fn stats(self: *const Self) Stats {
            return .{
                .output_packets = self.output_packets,
                .output_bytes = self.output_bytes,
                .input_packets = self.input_packets,
                .input_errors = self.input_errors,
                .recv_bytes = self.recv_bytes,
                .waitsnd = @intCast(kcp.waitsnd(self.inst)),
            };
        }

        fn sendPacket(self: *Self, channel: anytype, data: []const u8) Error!void {
            if (self.closing.load(.acquire)) return error.Closed;
            const packet = Packet.init(data) catch return error.TooLarge;
            const result = channel.send(packet) catch return error.Closed;
            if (!result.ok) return error.Closed;
        }

        fn sendPacketTimeout(self: *Self, channel: anytype, data: []const u8, timeout: glib.time.duration.Duration) Error!bool {
            if (self.closing.load(.acquire)) return error.Closed;
            const packet = Packet.init(data) catch return error.TooLarge;
            const result = channel.sendTimeout(packet, timeout) catch |err| switch (@as(anyerror, err)) {
                error.Timeout => return false,
                error.Closed => return error.Closed,
                else => return error.Unexpected,
            };
            if (!result.ok) return error.Closed;
            return true;
        }

        fn readPending(self: *Self, out: []u8) ?usize {
            if (self.read_pending) |packet| {
                const n = @min(out.len, packet.len - self.read_offset);
                @memcpy(out[0..n], packet.data[self.read_offset..][0..n]);
                self.read_offset += n;
                if (self.read_offset >= packet.len) {
                    self.read_pending = null;
                    self.read_offset = 0;
                }
                return n;
            }
            return null;
        }

        fn copyReadPacket(self: *Self, packet: Packet, out: []u8) usize {
            const n = @min(out.len, packet.len);
            @memcpy(out[0..n], packet.data[0..n]);
            if (n < packet.len) {
                self.read_pending = packet;
                self.read_offset = n;
            }
            return n;
        }

        fn workerMain(self: *Self) void {
            self.run() catch |err| {
                if (err == error.Closed and self.closing.load(.acquire)) return;
                if (self.last_output_error) |output_err| {
                    log.err("kcp worker stopped err={s} output_err={s}", .{ @errorName(err), @errorName(output_err) });
                } else {
                    log.err("kcp worker stopped err={s}", .{@errorName(err)});
                }
                self.close();
            };
        }

        fn run(self: *Self) Error!void {
            while (!self.closing.load(.acquire)) {
                try self.drainInput();
                try self.drainWrites();
                try self.updateKcp();
                try self.drainRecv();
                if (self.last_output_error) |_| return error.OutputFailed;
                grt.time.sleep(@as(glib.time.duration.Duration, @intCast(self.config.interval_ms)) * glib.time.duration.MilliSecond);
            }
        }

        fn drainInput(self: *Self) Error!void {
            while (true) {
                const result = self.input_ch.recvTimeout(0) catch |err| switch (@as(anyerror, err)) {
                    error.Timeout => return,
                    error.Closed => return error.Closed,
                    else => return error.Unexpected,
                };
                if (!result.ok) return error.Closed;
                const rc = kcp.input(self.inst, result.value.data[0..result.value.len].ptr, result.value.len);
                if (rc != 0) {
                    self.input_errors +|= 1;
                    return error.KcpInputFailed;
                }
                self.input_packets +|= 1;
            }
        }

        fn drainWrites(self: *Self) Error!void {
            while (true) {
                if (!self.canQueueKcpWrite()) return;
                const result = self.write_ch.recvTimeout(0) catch |err| switch (@as(anyerror, err)) {
                    error.Timeout => return,
                    error.Closed => return error.Closed,
                    else => return error.Unexpected,
                };
                if (!result.ok) return error.Closed;
                const rc = kcp.send(self.inst, result.value.data[0..result.value.len].ptr, @intCast(result.value.len));
                if (rc < 0) return error.KcpSendFailed;
            }
        }

        fn canQueueKcpWrite(self: *Self) bool {
            const limit: c_int = @intCast(@max(self.config.send_window, 1));
            return kcp.waitsnd(self.inst) < limit;
        }

        fn updateKcp(self: *Self) Error!void {
            kcp.update(self.inst, nowMs());
            return if (self.last_output_error) |_| error.OutputFailed else {};
        }

        fn drainRecv(self: *Self) Error!void {
            while (true) {
                if (self.pending_recv) |packet| {
                    if (!try self.tryQueueRecv(packet)) return;
                    self.pending_recv = null;
                    continue;
                }

                const peek = kcp.peeksize(self.inst);
                if (peek < 0) return;
                if (@as(usize, @intCast(peek)) > Packet.MAX_LEN) return error.KcpRecvFailed;
                var packet = Packet{ .len = @intCast(peek) };
                const rc = kcp.recv(self.inst, packet.data[0..].ptr, peek);
                if (rc < 0) return error.KcpRecvFailed;
                packet.len = @intCast(rc);
                self.recv_bytes +|= packet.len;
                if (!try self.tryQueueRecv(packet)) {
                    self.pending_recv = packet;
                    return;
                }
            }
        }

        fn tryQueueRecv(self: *Self, packet: Packet) Error!bool {
            const sent = self.recv_ch.sendTimeout(packet, 0) catch |err| switch (@as(anyerror, err)) {
                error.Timeout => return false,
                error.Closed => return error.Closed,
                else => return error.Unexpected,
            };
            if (!sent.ok) return error.Closed;
            return true;
        }

        fn nowMs() u32 {
            const now = grt.time.instant.now();
            return @truncate(@divFloor(now, glib.time.duration.MilliSecond));
        }

        fn outputCallback(buf: [*c]const u8, len: c_int, _: [*c]kcp.Kcp, user: ?*anyopaque) callconv(.c) c_int {
            const self: *Self = @ptrCast(@alignCast(user.?));
            if (len <= 0) return 0;
            const data = buf[0..@intCast(len)];
            self.output_fn(self.output_ctx, data) catch |err| {
                self.last_output_error = err;
                return -1;
            };
            self.output_packets +|= 1;
            self.output_bytes +|= data.len;
            return 0;
        }
    };
}

pub const Packet = struct {
    pub const MAX_LEN: usize = Config.DEFAULT_MAX_DATAGRAM_LEN;

    data: [MAX_LEN]u8 = undefined,
    len: usize = 0,

    pub fn init(data: []const u8) error{TooLarge}!Packet {
        if (data.len > MAX_LEN) return error.TooLarge;
        var packet = Packet{ .len = data.len };
        @memcpy(packet.data[0..data.len], data);
        return packet;
    }
};

pub const Stats = struct {
    output_packets: u64 = 0,
    output_bytes: u64 = 0,
    input_packets: u64 = 0,
    input_errors: u64 = 0,
    recv_bytes: u64 = 0,
    waitsnd: u32 = 0,
};

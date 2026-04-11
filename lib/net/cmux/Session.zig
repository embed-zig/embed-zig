const NetConn = @import("../Conn.zig");
const NetListener = @import("../Listener.zig");
const control = @import("control.zig");
const frame = @import("frame.zig");

pub fn make(comptime lib: type) type {
    const Allocator = lib.mem.Allocator;
    const Thread = lib.Thread;

    return struct {
        allocator: Allocator,
        bearer: NetConn,
        options: Options,
        mutex: Thread.Mutex = .{},
        accept_cond: Thread.Condition = .{},
        session_cond: Thread.Condition = .{},
        send_mutex: Thread.Mutex = .{},
        worker: ?Thread = null,
        closed: bool = false,
        session_ready: bool = false,
        startup_sent: bool = false,
        receive_storage: []u8,
        send_storage: []u8,
        channels: [64]?*ChannelState = [_]?*ChannelState{null} ** 64,
        accept_queue: lib.ArrayList(*ChannelState) = .{},

        const Self = @This();

        pub const Options = struct {
            role: control.Role,
            max_accept_queue: usize = 8,
            read_buffer_size: usize = 1024,
            write_buffer_size: usize = 1024,
        };

        pub const InitError = Allocator.Error || NetConn.WriteError || error{
            InvalidOptions,
            Unexpected,
        };

        pub const DialError = Allocator.Error || NetConn.WriteError || error{
            Closed,
            InvalidDLCI,
            AlreadyOpen,
            Rejected,
            Unexpected,
        };

        pub const AcceptError = error{
            Closed,
            Unexpected,
        };

        pub const ChannelState = struct {
            allocator: Allocator,
            dlci: u8,
            mutex: Thread.Mutex = .{},
            cond: Thread.Condition = .{},
            rx: lib.ArrayList(u8) = .{},
            refs: usize = 1,
            registered: bool = true,
            open: bool = false,
            rejected: bool = false,
            closed: bool = false,
            queued_for_accept: bool = false,
            read_timeout_ms: ?u32 = null,
            write_timeout_ms: ?u32 = null,
        };

        pub fn init(allocator: Allocator, bearer: NetConn, options: Options) InitError!*Self {
            try validateOptions(options);
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            const send_storage_len, const overflow = @addWithOverflow(options.write_buffer_size, @as(usize, 8));
            if (overflow != 0) return error.OutOfMemory;
            const receive_storage = try allocator.alloc(u8, options.read_buffer_size + 8);
            errdefer allocator.free(receive_storage);
            const send_storage = try allocator.alloc(u8, send_storage_len);
            errdefer allocator.free(send_storage);

            self.* = .{
                .allocator = allocator,
                .bearer = bearer,
                .options = options,
                .receive_storage = receive_storage,
                .send_storage = send_storage,
            };
            errdefer {
                self.close();
                if (self.worker) |worker| worker.join();
                self.bearer.deinit();
                allocator.free(self.receive_storage);
                allocator.free(self.send_storage);
            }

            const worker = Thread.spawn(.{}, workerMain, .{self}) catch return error.Unexpected;
            self.worker = worker;

            if (options.role == .initiator) try self.startSessionHandshake();
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.close();
            if (self.worker) |worker| worker.join();

            self.mutex.lock();
            var pending = self.accept_queue;
            self.accept_queue = .{};
            const channel_refs = self.channels;
            self.channels = [_]?*ChannelState{null} ** 64;
            self.mutex.unlock();

            for (pending.items) |channel| self.releaseChannel(channel);
            pending.deinit(self.allocator);
            for (channel_refs) |maybe_channel| {
                if (maybe_channel) |channel| self.releaseChannel(channel);
            }

            self.bearer.deinit();
            self.allocator.free(self.receive_storage);
            self.allocator.free(self.send_storage);
            self.allocator.destroy(self);
        }

        pub fn close(self: *Self) void {
            if (self.beginClose()) {
                self.sendControl(0, .disc) catch {};
                self.bearer.close();
            }
        }

        pub fn listen(self: *Self) NetListener.ListenError!void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.closed) return error.Closed;
        }

        pub fn dialChannel(self: *Self, dlci: u16) DialError!*ChannelState {
            if (!control.isValidUserDlci(dlci)) return error.InvalidDLCI;
            try self.waitForSessionReady();

            self.mutex.lock();
            if (self.closed) {
                self.mutex.unlock();
                return error.Closed;
            }
            if (self.channels[dlci] != null) {
                self.mutex.unlock();
                return error.AlreadyOpen;
            }

            const channel = self.createChannelLocked(@intCast(dlci)) catch |err| {
                self.mutex.unlock();
                return err;
            };
            channel.open = false;
            self.retainChannel(channel);
            self.mutex.unlock();

            defer self.releaseChannel(channel);
            errdefer self.closeChannel(channel);

            try self.sendControl(@intCast(dlci), .sabm);
            try self.waitForOpen(channel);
            return channel;
        }

        pub fn acceptChannel(self: *Self) AcceptError!*ChannelState {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (true) {
                while (self.accept_queue.items.len == 0 and !self.closed) {
                    self.accept_cond.wait(&self.mutex);
                }
                if (self.closed and self.accept_queue.items.len == 0) return error.Closed;

                const channel = self.accept_queue.swapRemove(0);
                channel.mutex.lock();
                channel.queued_for_accept = false;
                const usable = !channel.closed;
                channel.mutex.unlock();
                if (usable) return channel;
                self.releaseChannel(channel);
            }
        }

        pub fn retainChannel(self: *Self, channel: *ChannelState) void {
            _ = self;
            channel.mutex.lock();
            channel.refs += 1;
            channel.mutex.unlock();
        }

        pub fn releaseChannel(self: *Self, channel: *ChannelState) void {
            _ = self;
            channel.mutex.lock();
            lib.debug.assert(channel.refs > 0);
            channel.refs -= 1;
            const refs = channel.refs;
            channel.mutex.unlock();
            if (refs != 0) return;

            channel.rx.deinit(channel.allocator);
            channel.allocator.destroy(channel);
        }

        pub fn readChannel(self: *Self, channel: *ChannelState, buf: []u8) NetConn.ReadError!usize {
            _ = self;
            if (buf.len == 0) return 0;

            channel.mutex.lock();
            defer channel.mutex.unlock();

            while (availableRx(channel) == 0 and !channel.closed) {
                if (channel.read_timeout_ms) |timeout_ms| {
                    channel.cond.timedWait(&channel.mutex, timeout_ms * lib.time.ns_per_ms) catch return error.TimedOut;
                } else {
                    channel.cond.wait(&channel.mutex);
                }
            }

            if (availableRx(channel) == 0 and channel.closed) return error.EndOfStream;

            const rx = channel.rx.items[0..availableRx(channel)];
            const n = @min(buf.len, rx.len);
            @memcpy(buf[0..n], rx[0..n]);
            if (n == rx.len) {
                channel.rx.clearRetainingCapacity();
            } else {
                lib.mem.copyForwards(u8, channel.rx.items[0 .. rx.len - n], channel.rx.items[n..rx.len]);
                channel.rx.items.len = rx.len - n;
            }
            return n;
        }

        pub fn writeChannel(self: *Self, channel: *ChannelState, buf: []const u8) NetConn.WriteError!usize {
            if (buf.len == 0) return 0;

            channel.mutex.lock();
            const closed = channel.closed or !channel.open;
            const write_timeout_ms = channel.write_timeout_ms;
            channel.mutex.unlock();

            if (closed) return error.BrokenPipe;

            var written: usize = 0;
            while (written < buf.len) {
                const chunk_len = @min(buf.len - written, self.options.write_buffer_size);
                self.sendFrame(write_timeout_ms, .{
                    .dlci = channel.dlci,
                    .cr = control.commandCr(self.options.role),
                    .frame_type = .uih,
                    .info = buf[written .. written + chunk_len],
                }) catch |err| return switch (err) {
                    error.ConnectionRefused => error.ConnectionRefused,
                    error.ConnectionReset => error.ConnectionReset,
                    error.BrokenPipe => error.BrokenPipe,
                    error.TimedOut => error.TimedOut,
                    else => error.Unexpected,
                };
                written += chunk_len;
            }
            return written;
        }

        pub fn closeChannel(self: *Self, channel: *ChannelState) void {
            var should_unregister = false;

            channel.mutex.lock();
            if (!channel.closed) {
                channel.closed = true;
                channel.cond.broadcast();
                should_unregister = channel.registered;
            }
            channel.mutex.unlock();

            if (!should_unregister) return;

            self.sendControl(channel.dlci, .disc) catch {};
            self.unregisterChannel(channel);
        }

        pub fn setChannelReadTimeout(self: *Self, channel: *ChannelState, ms: ?u32) void {
            _ = self;
            channel.mutex.lock();
            channel.read_timeout_ms = ms;
            channel.mutex.unlock();
        }

        pub fn setChannelWriteTimeout(self: *Self, channel: *ChannelState, ms: ?u32) void {
            _ = self;
            channel.mutex.lock();
            channel.write_timeout_ms = ms;
            channel.mutex.unlock();
        }

        pub fn channelDlci(_: *Self, channel: *const ChannelState) u8 {
            return channel.dlci;
        }

        fn createChannelLocked(self: *Self, dlci: u8) Allocator.Error!*ChannelState {
            const channel = try self.allocator.create(ChannelState);
            errdefer self.allocator.destroy(channel);
            channel.* = .{
                .allocator = self.allocator,
                .dlci = dlci,
            };
            self.channels[dlci] = channel;
            return channel;
        }

        fn validateOptions(options: Options) error{InvalidOptions}!void {
            if (options.max_accept_queue == 0) return error.InvalidOptions;
            if (options.read_buffer_size == 0) return error.InvalidOptions;
            if (options.write_buffer_size == 0) return error.InvalidOptions;
        }

        fn waitForSessionReady(self: *Self) DialError!void {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (!self.session_ready and !self.closed) {
                self.session_cond.wait(&self.mutex);
            }
            if (self.closed and !self.session_ready) return error.Closed;
        }

        fn startSessionHandshake(self: *Self) NetConn.WriteError!void {
            self.mutex.lock();
            const should_send = !self.startup_sent and !self.closed;
            if (should_send) self.startup_sent = true;
            self.mutex.unlock();

            if (!should_send) return;
            try self.sendControl(0, .sabm);
        }

        fn waitForOpen(self: *Self, channel: *ChannelState) DialError!void {
            _ = self;
            channel.mutex.lock();
            defer channel.mutex.unlock();
            while (!channel.open and !channel.rejected and !channel.closed) {
                channel.cond.wait(&channel.mutex);
            }
            if (channel.rejected) return error.Rejected;
            if (!channel.open) return error.Closed;
        }

        fn sendControl(self: *Self, dlci: u8, frame_type: control.FrameType) NetConn.WriteError!void {
            const cr = switch (frame_type) {
                .ua, .dm => control.responseCr(self.options.role),
                else => control.commandCr(self.options.role),
            };
            try self.sendFrame(null, .{
                .dlci = dlci,
                .cr = cr,
                .pf = true,
                .frame_type = frame_type,
            });
        }

        fn sendFrame(self: *Self, timeout_ms: ?u32, cmux_frame: frame.Frame) NetConn.WriteError!void {
            self.send_mutex.lock();
            defer self.send_mutex.unlock();

            const encoded = frame.encode(self.send_storage, cmux_frame) catch return error.Unexpected;
            self.bearer.setWriteTimeout(timeout_ms);
            defer self.bearer.setWriteTimeout(null);
            try writeAll(self.bearer, encoded);
        }

        fn workerMain(self: *Self) void {
            while (true) {
                const next = self.readFrame() catch |err| {
                    if (err == error.EndOfStream) break;
                    self.failSession();
                    break;
                };
                self.handleFrame(next) catch {
                    self.failSession();
                    break;
                };
            }
            self.finishWorker();
        }

        fn readFrame(self: *Self) (NetConn.ReadError || frame.DecodeError || error{FrameTooLarge})!frame.Frame {
            var header: [4]u8 = undefined;
            var skipped: usize = 0;

            while (true) {
                const byte = try readByte(self.bearer);
                if (byte == control.flag) break;
                skipped += 1;
                if (skipped > self.options.read_buffer_size) return error.FrameTooLarge;
            }

            header[0] = try readByte(self.bearer);
            header[1] = try readByte(self.bearer);
            header[2] = try readByte(self.bearer);

            var info_len: usize = header[2] >> 1;
            var header_len: usize = 4;
            if ((header[2] & 0x01) == 0) {
                header[3] = try readByte(self.bearer);
                info_len |= (@as(usize, header[3]) << 7);
                header_len += 1;
            }

            if (info_len > self.options.read_buffer_size) return error.FrameTooLarge;

            const storage = self.receive_storage;
            storage[0] = control.flag;
            @memcpy(storage[1..header_len], header[0 .. header_len - 1]);

            const total_len = 1 + (header_len - 1) + info_len + 1 + 1;
            if (total_len > storage.len) return error.FrameTooLarge;

            for (storage[header_len .. total_len]) |*byte| {
                byte.* = try readByte(self.bearer);
            }
            return try frame.decode(storage[0..total_len]);
        }

        fn handleFrame(self: *Self, incoming: frame.Frame) !void {
            try self.validateIncomingCr(incoming);
            if (incoming.dlci == 0) {
                try self.handleSessionFrame(incoming);
                return;
            }

            switch (incoming.frame_type) {
                .sabm => try self.handleOpenRequest(incoming.dlci),
                .ua => self.handleOpenAck(incoming.dlci),
                .disc => try self.handleDisc(incoming.dlci),
                .dm => self.handleReject(incoming.dlci),
                .uih => try self.handleData(incoming.dlci, incoming.info),
            }
        }

        fn handleSessionFrame(self: *Self, incoming: frame.Frame) !void {
            switch (incoming.frame_type) {
                .sabm => {
                    self.mutex.lock();
                    self.session_ready = true;
                    self.session_cond.broadcast();
                    self.mutex.unlock();
                    try self.sendControl(0, .ua);
                },
                .ua => {
                    self.mutex.lock();
                    self.session_ready = true;
                    self.session_cond.broadcast();
                    self.mutex.unlock();
                },
                .disc => {
                    try self.sendControl(0, .ua);
                    if (self.beginClose()) self.bearer.close();
                },
                .dm => self.failSession(),
                .uih => {},
            }
        }

        fn handleOpenRequest(self: *Self, dlci: u8) !void {
            var queue_err: ?Allocator.Error = null;

            self.mutex.lock();
            if (self.closed) {
                self.mutex.unlock();
                return;
            }

            if (self.channels[dlci]) |existing| {
                existing.mutex.lock();
                const is_closed = existing.closed;
                existing.mutex.unlock();
                if (!is_closed) {
                    self.mutex.unlock();
                    try self.sendControl(dlci, .dm);
                    return;
                }
            }

            const channel = if (self.channels[dlci]) |existing|
                existing
            else
                self.createChannelLocked(dlci) catch |err| {
                    self.mutex.unlock();
                    return err;
                };

            channel.mutex.lock();
            channel.rx.clearRetainingCapacity();
            channel.open = true;
            channel.rejected = false;
            channel.closed = false;
            if (!channel.queued_for_accept) {
                if (self.accept_queue.items.len < self.options.max_accept_queue) {
                    self.accept_queue.append(self.allocator, channel) catch |err| {
                        channel.closed = true;
                        queue_err = err;
                    };
                    if (queue_err == null) {
                        channel.queued_for_accept = true;
                        channel.refs += 1;
                    }
                } else {
                    channel.closed = true;
                }
            }
            channel.cond.broadcast();
            const accepted = !channel.closed;
            channel.mutex.unlock();

            self.mutex.unlock();

            if (queue_err) |err| {
                self.unregisterChannel(channel);
                self.sendControl(dlci, .dm) catch {};
                return err;
            }
            if (accepted) {
                try self.sendControl(dlci, .ua);
                self.accept_cond.broadcast();
            } else {
                self.unregisterChannel(channel);
                try self.sendControl(dlci, .dm);
            }
        }

        fn handleOpenAck(self: *Self, dlci: u8) void {
            const channel = self.lookupChannel(dlci) orelse return;
            channel.mutex.lock();
            channel.open = true;
            channel.cond.broadcast();
            channel.mutex.unlock();
        }

        fn handleDisc(self: *Self, dlci: u8) !void {
            const channel = self.lookupChannel(dlci) orelse {
                try self.sendControl(dlci, .dm);
                return;
            };

            channel.mutex.lock();
            channel.closed = true;
            channel.cond.broadcast();
            channel.mutex.unlock();

            self.unregisterChannel(channel);
            try self.sendControl(dlci, .ua);
        }

        fn handleReject(self: *Self, dlci: u8) void {
            const channel = self.lookupChannel(dlci) orelse return;
            channel.mutex.lock();
            channel.rejected = true;
            channel.closed = true;
            channel.cond.broadcast();
            channel.mutex.unlock();
            self.unregisterChannel(channel);
        }

        fn handleData(self: *Self, dlci: u8, info: []const u8) !void {
            const channel = self.lookupChannel(dlci) orelse return;
            channel.mutex.lock();
            defer channel.mutex.unlock();
            if (channel.closed) return;
            const next_len, const overflow = @addWithOverflow(channel.rx.items.len, info.len);
            if (overflow != 0 or next_len > self.options.read_buffer_size) return error.FrameTooLarge;
            try channel.rx.appendSlice(self.allocator, info);
            channel.cond.broadcast();
        }

        fn validateIncomingCr(self: *Self, incoming: frame.Frame) !void {
            const peer_role: control.Role = switch (self.options.role) {
                .initiator => .responder,
                .responder => .initiator,
            };
            const expected_cr = switch (incoming.frame_type) {
                .ua, .dm => control.responseCr(peer_role),
                .sabm, .disc, .uih => control.commandCr(peer_role),
            };
            if (incoming.cr != expected_cr) return error.InvalidCr;
        }

        fn lookupChannel(self: *Self, dlci: u8) ?*ChannelState {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.channels[dlci];
        }

        fn unregisterChannel(self: *Self, channel: *ChannelState) void {
            var release_count: usize = 0;

            self.mutex.lock();
            if (channel.registered and self.channels[channel.dlci] == channel) {
                self.channels[channel.dlci] = null;
                channel.mutex.lock();
                channel.registered = false;
                channel.mutex.unlock();
                release_count += 1;
            }

            var index: ?usize = null;
            for (self.accept_queue.items, 0..) |queued, i| {
                if (queued == channel) {
                    index = i;
                    break;
                }
            }
            if (index) |i| {
                _ = self.accept_queue.swapRemove(i);
                channel.mutex.lock();
                channel.queued_for_accept = false;
                channel.mutex.unlock();
                release_count += 1;
            }
            self.mutex.unlock();

            var remaining = release_count;
            while (remaining != 0) : (remaining -= 1) self.releaseChannel(channel);
        }

        fn beginClose(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.closed) return false;
            self.closed = true;
            self.accept_cond.broadcast();
            self.session_cond.broadcast();

            for (self.channels) |maybe_channel| {
                if (maybe_channel) |channel| {
                    channel.mutex.lock();
                    channel.closed = true;
                    channel.cond.broadcast();
                    channel.mutex.unlock();
                }
            }
            return true;
        }

        fn failSession(self: *Self) void {
            if (self.beginClose()) self.bearer.close();
        }

        fn finishWorker(self: *Self) void {
            if (self.beginClose()) self.bearer.close();
        }

        fn availableRx(channel: *ChannelState) usize {
            return channel.rx.items.len;
        }
    };
}

fn readByte(conn: NetConn) NetConn.ReadError!u8 {
    var byte: [1]u8 = undefined;
    const n = try conn.read(&byte);
    if (n == 0) return error.EndOfStream;
    return byte[0];
}

fn writeAll(conn: NetConn, buf: []const u8) NetConn.WriteError!void {
    var offset: usize = 0;
    while (offset < buf.len) {
        const n = try conn.write(buf[offset..]);
        if (n == 0) return error.BrokenPipe;
        offset += n;
    }
}


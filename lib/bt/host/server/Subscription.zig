//! host.server.Subscription — accepted server-side push sink.

pub fn Subscription(comptime lib: type, comptime ServerType: type) type {
    return struct {
        pub const WriteError = ServerType.PushError || error{
            Closed,
            UnsupportedMode,
        };

        pub const State = struct {
            allocator: lib.mem.Allocator,
            server: *ServerType,
            conn_handle: u16,
            service_uuid: u16,
            char_uuid: u16,
            cccd_value: u16,
            internal: bool,
            mutex: lib.Thread.Mutex = .{},
            cond: lib.Thread.Condition = .{},
            closed: bool = false,
            active_ops: usize = 0,
        };

        state: *State,

        const Self = @This();

        pub fn init(
            allocator: lib.mem.Allocator,
            server: *ServerType,
            conn_handle: u16,
            service_uuid: u16,
            char_uuid: u16,
            cccd_value: u16,
            internal: bool,
        ) !Self {
            const state = try allocator.create(State);
            state.* = .{
                .allocator = allocator,
                .server = server,
                .conn_handle = conn_handle,
                .service_uuid = service_uuid,
                .char_uuid = char_uuid,
                .cccd_value = cccd_value,
                .internal = internal,
            };
            return .{ .state = state };
        }

        pub fn deinit(self: *Self) void {
            close(self.state);
            _ = self.state.server.unregisterSubscription(self.state);
            destroyState(self.state);
        }

        pub fn write(self: *Self, data: []const u8) WriteError!void {
            if (self.canNotify()) return self.notify(data);
            return self.indicate(data);
        }

        pub fn notify(self: *Self, data: []const u8) WriteError!void {
            try beginWrite(self.state, 0x0001);
            defer endWrite(self.state);
            return self.state.server.push(self.state.conn_handle, self.state.char_uuid, .notify, data);
        }

        pub fn indicate(self: *Self, data: []const u8) WriteError!void {
            try beginWrite(self.state, 0x0002);
            defer endWrite(self.state);
            return self.state.server.push(self.state.conn_handle, self.state.char_uuid, .indicate, data);
        }

        pub fn connHandle(self: *const Self) u16 {
            return self.state.conn_handle;
        }

        pub fn serviceUuid(self: *const Self) u16 {
            return self.state.service_uuid;
        }

        pub fn charUuid(self: *const Self) u16 {
            return self.state.char_uuid;
        }

        pub fn cccdValue(self: *const Self) u16 {
            return self.state.cccd_value;
        }

        pub fn canNotify(self: *const Self) bool {
            return (self.state.cccd_value & 0x0001) != 0;
        }

        pub fn canIndicate(self: *const Self) bool {
            return (self.state.cccd_value & 0x0002) != 0;
        }

        pub fn matches(state: *const State, conn_handle: u16, service_uuid: u16, char_uuid: u16) bool {
            return state.conn_handle == conn_handle and state.service_uuid == service_uuid and state.char_uuid == char_uuid;
        }

        pub fn matchesConn(state: *const State, conn_handle: u16) bool {
            return state.conn_handle == conn_handle;
        }

        pub fn close(state: *State) void {
            state.mutex.lock();
            defer state.mutex.unlock();
            state.closed = true;
            state.cond.broadcast();
        }

        pub fn destroyState(state: *State) void {
            state.mutex.lock();
            state.closed = true;
            while (state.active_ops != 0) {
                state.cond.wait(&state.mutex);
            }
            state.mutex.unlock();
            state.allocator.destroy(state);
        }

        fn beginWrite(state: *State, required_bits: u16) WriteError!void {
            state.mutex.lock();
            errdefer state.mutex.unlock();
            if (state.closed) return error.Closed;
            if ((state.cccd_value & required_bits) == 0) return error.UnsupportedMode;
            state.active_ops += 1;
            state.mutex.unlock();
        }

        fn endWrite(state: *State) void {
            state.mutex.lock();
            defer state.mutex.unlock();
            state.active_ops -= 1;
            if (state.active_ops == 0) {
                state.cond.broadcast();
            }
        }
    };
}

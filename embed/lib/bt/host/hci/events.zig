//! HCI event decoder (Bluetooth Core Spec Vol 4 Part E).
//!
//! Pure stateless decoder — parses raw HCI event bytes into a tagged union.
//! No I/O, no Transport dependency.
//!
//! Event packet format: [indicator(1)][event_code(1)][param_len(1)][params...]
//! Indicator byte 0x04 = HCI Event.

const glib = @import("glib");

const Status = @import("status.zig").Status;

pub const INDICATOR: u8 = 0x04;
pub const HEADER_LEN: usize = 3; // indicator + event_code + param_len

// --- Event codes ---
pub const DISCONNECTION_COMPLETE: u8 = 0x05;
pub const COMMAND_COMPLETE: u8 = 0x0E;
pub const COMMAND_STATUS: u8 = 0x0F;
pub const NUM_COMPLETED_PACKETS: u8 = 0x13;
pub const LE_META: u8 = 0x3E;

// --- LE sub-event codes ---
pub const LE_CONNECTION_COMPLETE: u8 = 0x01;
pub const LE_ADVERTISING_REPORT: u8 = 0x02;
pub const LE_CONNECTION_UPDATE_COMPLETE: u8 = 0x03;
pub const LE_LONG_TERM_KEY_REQUEST: u8 = 0x05;
pub const LE_DATA_LENGTH_CHANGE: u8 = 0x07;
pub const LE_ENHANCED_CONNECTION_COMPLETE: u8 = 0x0A;

pub const Event = union(enum) {
    command_complete: CommandComplete,
    command_status: CommandStatus,
    disconnection_complete: DisconnectionComplete,
    num_completed_packets: NumCompletedPackets,
    le_connection_complete: LeConnectionComplete,
    le_advertising_report: LeAdvertisingReport,
    le_connection_update_complete: LeConnectionUpdateComplete,
    unknown: Unknown,
};

pub const CommandComplete = struct {
    num_cmd_packets: u8,
    opcode: u16,
    status: Status,
    return_params: []const u8,
};

pub const CommandStatus = struct {
    status: Status,
    num_cmd_packets: u8,
    opcode: u16,
};

pub const DisconnectionComplete = struct {
    status: Status,
    conn_handle: u16,
    reason: Status,
};

pub const NumCompletedPackets = struct {
    num_handles: u8,
    data: []const u8,

    pub fn getHandle(self: NumCompletedPackets, index: usize) ?u16 {
        const offset = index * 4;
        if (offset + 2 > self.data.len) return null;
        return glib.std.mem.readInt(u16, self.data[offset..][0..2], .little);
    }

    pub fn getCount(self: NumCompletedPackets, index: usize) ?u16 {
        const offset = index * 4 + 2;
        if (offset + 2 > self.data.len) return null;
        return glib.std.mem.readInt(u16, self.data[offset..][0..2], .little);
    }
};

pub const LeConnectionComplete = struct {
    status: Status,
    conn_handle: u16,
    role: u8,
    peer_addr_type: u8,
    peer_addr: [6]u8,
    conn_interval: u16,
    conn_latency: u16,
    supervision_timeout: u16,
};

pub const LeAdvertisingReport = struct {
    num_reports: u8,
    data: []const u8,
};

pub const LeConnectionUpdateComplete = struct {
    status: Status,
    conn_handle: u16,
    conn_interval: u16,
    conn_latency: u16,
    supervision_timeout: u16,
};

pub const Unknown = struct {
    event_code: u8,
    data: []const u8,
};

/// Decode an HCI event from raw bytes (including indicator byte).
/// Returns null if the packet is too short or not an event.
pub fn decode(raw: []const u8) ?Event {
    if (raw.len < HEADER_LEN) return null;
    if (raw[0] != INDICATOR) return null;

    const event_code = raw[1];
    const param_len: usize = raw[2];
    if (raw.len < HEADER_LEN + param_len) return null;

    const params = raw[HEADER_LEN..][0..param_len];

    return switch (event_code) {
        COMMAND_COMPLETE => decodeCommandComplete(params),
        COMMAND_STATUS => decodeCommandStatus(params),
        DISCONNECTION_COMPLETE => decodeDisconnectionComplete(params),
        NUM_COMPLETED_PACKETS => decodeNumCompletedPackets(params),
        LE_META => decodeLeMetaEvent(params),
        else => .{ .unknown = .{ .event_code = event_code, .data = params } },
    };
}

/// Decode without indicator byte (event_code is first byte).
pub fn decodeNoIndicator(raw: []const u8) ?Event {
    if (raw.len < 2) return null;
    const event_code = raw[0];
    const param_len: usize = raw[1];
    if (raw.len < 2 + param_len) return null;

    const params = raw[2..][0..param_len];

    return switch (event_code) {
        COMMAND_COMPLETE => decodeCommandComplete(params),
        COMMAND_STATUS => decodeCommandStatus(params),
        DISCONNECTION_COMPLETE => decodeDisconnectionComplete(params),
        NUM_COMPLETED_PACKETS => decodeNumCompletedPackets(params),
        LE_META => decodeLeMetaEvent(params),
        else => .{ .unknown = .{ .event_code = event_code, .data = params } },
    };
}

fn decodeCommandComplete(params: []const u8) Event {
    if (params.len < 4) return .{ .unknown = .{ .event_code = COMMAND_COMPLETE, .data = params } };
    return .{ .command_complete = .{
        .num_cmd_packets = params[0],
        .opcode = glib.std.mem.readInt(u16, params[1..3], .little),
        .status = Status.fromByte(params[3]),
        .return_params = if (params.len > 4) params[4..] else &.{},
    } };
}

fn decodeCommandStatus(params: []const u8) Event {
    if (params.len < 4) return .{ .unknown = .{ .event_code = COMMAND_STATUS, .data = params } };
    return .{ .command_status = .{
        .status = Status.fromByte(params[0]),
        .num_cmd_packets = params[1],
        .opcode = glib.std.mem.readInt(u16, params[2..4], .little),
    } };
}

fn decodeDisconnectionComplete(params: []const u8) Event {
    if (params.len < 4) return .{ .unknown = .{ .event_code = DISCONNECTION_COMPLETE, .data = params } };
    return .{ .disconnection_complete = .{
        .status = Status.fromByte(params[0]),
        .conn_handle = glib.std.mem.readInt(u16, params[1..3], .little) & 0x0FFF,
        .reason = Status.fromByte(params[3]),
    } };
}

fn decodeNumCompletedPackets(params: []const u8) Event {
    if (params.len < 1) return .{ .unknown = .{ .event_code = NUM_COMPLETED_PACKETS, .data = params } };
    return .{ .num_completed_packets = .{
        .num_handles = params[0],
        .data = if (params.len > 1) params[1..] else &.{},
    } };
}

fn decodeLeMetaEvent(params: []const u8) Event {
    if (params.len < 1) return .{ .unknown = .{ .event_code = LE_META, .data = params } };
    const sub = params[0];
    const sub_params = if (params.len > 1) params[1..] else &[_]u8{};

    return switch (sub) {
        LE_CONNECTION_COMPLETE => decodeLeConnectionComplete(sub_params),
        LE_ENHANCED_CONNECTION_COMPLETE => decodeLeEnhancedConnectionComplete(sub_params),
        LE_ADVERTISING_REPORT => .{ .le_advertising_report = .{
            .num_reports = if (sub_params.len > 0) sub_params[0] else 0,
            .data = sub_params,
        } },
        LE_CONNECTION_UPDATE_COMPLETE => decodeLeConnectionUpdateComplete(sub_params),
        else => .{ .unknown = .{ .event_code = LE_META, .data = params } },
    };
}

fn decodeLeConnectionComplete(params: []const u8) Event {
    if (params.len < 18) return .{ .unknown = .{ .event_code = LE_META, .data = params } };
    return .{ .le_connection_complete = .{
        .status = Status.fromByte(params[0]),
        .conn_handle = glib.std.mem.readInt(u16, params[1..3], .little) & 0x0FFF,
        .role = params[3],
        .peer_addr_type = params[4],
        .peer_addr = params[5..11].*,
        .conn_interval = glib.std.mem.readInt(u16, params[11..13], .little),
        .conn_latency = glib.std.mem.readInt(u16, params[13..15], .little),
        .supervision_timeout = glib.std.mem.readInt(u16, params[15..17], .little),
    } };
}

fn decodeLeEnhancedConnectionComplete(params: []const u8) Event {
    if (params.len < 30) return .{ .unknown = .{ .event_code = LE_META, .data = params } };
    return .{ .le_connection_complete = .{
        .status = Status.fromByte(params[0]),
        .conn_handle = glib.std.mem.readInt(u16, params[1..3], .little) & 0x0FFF,
        .role = params[3],
        .peer_addr_type = params[4],
        .peer_addr = params[5..11].*,
        .conn_interval = glib.std.mem.readInt(u16, params[23..25], .little),
        .conn_latency = glib.std.mem.readInt(u16, params[25..27], .little),
        .supervision_timeout = glib.std.mem.readInt(u16, params[27..29], .little),
    } };
}

fn decodeLeConnectionUpdateComplete(params: []const u8) Event {
    if (params.len < 9) return .{ .unknown = .{ .event_code = LE_META, .data = params } };
    return .{ .le_connection_update_complete = .{
        .status = Status.fromByte(params[0]),
        .conn_handle = glib.std.mem.readInt(u16, params[1..3], .little) & 0x0FFF,
        .conn_interval = glib.std.mem.readInt(u16, params[3..5], .little),
        .conn_latency = glib.std.mem.readInt(u16, params[5..7], .little),
        .supervision_timeout = glib.std.mem.readInt(u16, params[7..9], .little),
    } };
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn run() !void {
            {
                const raw = [_]u8{ 0x04, 0x0E, 0x04, 0x01, 0x03, 0x0C, 0x00 };
                const evt = decode(&raw) orelse return error.DecodeFailed;
                switch (evt) {
                    .command_complete => |cc| {
                        try grt.std.testing.expectEqual(@as(u8, 1), cc.num_cmd_packets);
                        try grt.std.testing.expectEqual(@as(u16, 0x0C03), cc.opcode);
                        try grt.std.testing.expect(cc.status.isSuccess());
                    },
                    else => return error.WrongEvent,
                }
            }

            {
                const raw = [_]u8{ 0x04, 0x0F, 0x04, 0x00, 0x01, 0x0D, 0x20 };
                const evt = decode(&raw) orelse return error.DecodeFailed;
                switch (evt) {
                    .command_status => |cs| {
                        try grt.std.testing.expect(cs.status.isSuccess());
                        try grt.std.testing.expectEqual(@as(u16, 0x200D), cs.opcode);
                    },
                    else => return error.WrongEvent,
                }
            }

            {
                const raw = [_]u8{ 0x04, 0x05, 0x04, 0x00, 0x40, 0x00, 0x13 };
                const evt = decode(&raw) orelse return error.DecodeFailed;
                switch (evt) {
                    .disconnection_complete => |dc| {
                        try grt.std.testing.expect(dc.status.isSuccess());
                        try grt.std.testing.expectEqual(@as(u16, 0x0040), dc.conn_handle);
                        try grt.std.testing.expectEqual(Status.remote_user_terminated, dc.reason);
                    },
                    else => return error.WrongEvent,
                }
            }

            {
                const raw = [_]u8{ 0x04, 0x13, 0x05, 0x01, 0x40, 0x00, 0x02, 0x00 };
                const evt = decode(&raw) orelse return error.DecodeFailed;
                switch (evt) {
                    .num_completed_packets => |ncp| {
                        try grt.std.testing.expectEqual(@as(u8, 1), ncp.num_handles);
                        try grt.std.testing.expectEqual(@as(?u16, 0x0040), ncp.getHandle(0));
                        try grt.std.testing.expectEqual(@as(?u16, 2), ncp.getCount(0));
                    },
                    else => return error.WrongEvent,
                }
            }

            {
                var raw: [3 + 1 + 18]u8 = undefined;
                raw[0] = 0x04;
                raw[1] = 0x3E;
                raw[2] = 19;
                raw[3] = 0x01;
                raw[4] = 0x00;
                raw[5] = 0x40;
                raw[6] = 0x00;
                raw[7] = 0x01;
                raw[8] = 0x00;
                @memcpy(raw[9..15], &[6]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF });
                grt.std.mem.writeInt(u16, raw[15..17], 0x0018, .little);
                grt.std.mem.writeInt(u16, raw[17..19], 0x0000, .little);
                grt.std.mem.writeInt(u16, raw[19..21], 0x00C8, .little);

                const evt = decode(&raw) orelse return error.DecodeFailed;
                switch (evt) {
                    .le_connection_complete => |lc| {
                        try grt.std.testing.expect(lc.status.isSuccess());
                        try grt.std.testing.expectEqual(@as(u16, 0x0040), lc.conn_handle);
                        try grt.std.testing.expectEqual(@as(u8, 1), lc.role);
                        try grt.std.testing.expectEqual(@as(u8, 0xAA), lc.peer_addr[0]);
                    },
                    else => return error.WrongEvent,
                }
            }

            {
                var raw: [3 + 1 + 30]u8 = undefined;
                raw[0] = 0x04;
                raw[1] = 0x3E;
                raw[2] = 31;
                raw[3] = 0x0A;
                raw[4] = 0x00;
                raw[5] = 0x40;
                raw[6] = 0x00;
                raw[7] = 0x01;
                raw[8] = 0x00;
                @memcpy(raw[9..15], &[6]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF });
                @memcpy(raw[15..21], &[6]u8{ 1, 2, 3, 4, 5, 6 });
                @memcpy(raw[21..27], &[6]u8{ 7, 8, 9, 10, 11, 12 });
                grt.std.mem.writeInt(u16, raw[27..29], 0x0018, .little);
                grt.std.mem.writeInt(u16, raw[29..31], 0x0001, .little);
                grt.std.mem.writeInt(u16, raw[31..33], 0x00C8, .little);
                raw[33] = 0;

                const evt = decode(&raw) orelse return error.DecodeFailed;
                switch (evt) {
                    .le_connection_complete => |lc| {
                        try grt.std.testing.expect(lc.status.isSuccess());
                        try grt.std.testing.expectEqual(@as(u16, 0x0040), lc.conn_handle);
                        try grt.std.testing.expectEqual(@as(u8, 0xAA), lc.peer_addr[0]);
                        try grt.std.testing.expectEqual(@as(u16, 0x0018), lc.conn_interval);
                        try grt.std.testing.expectEqual(@as(u16, 0x0001), lc.conn_latency);
                        try grt.std.testing.expectEqual(@as(u16, 0x00C8), lc.supervision_timeout);
                    },
                    else => return error.WrongEvent,
                }
            }

            {
                const raw = [_]u8{ 0x04, 0xFF, 0x02, 0x01, 0x02 };
                const evt = decode(&raw) orelse return error.DecodeFailed;
                switch (evt) {
                    .unknown => |u| {
                        try grt.std.testing.expectEqual(@as(u8, 0xFF), u.event_code);
                        try grt.std.testing.expectEqual(@as(usize, 2), u.data.len);
                    },
                    else => return error.WrongEvent,
                }
            }

            const no_indicator = decodeNoIndicator(&.{ 0x0E, 0x04, 0x01, 0x03, 0x0C, 0x00 }) orelse return error.DecodeFailed;
            switch (no_indicator) {
                .command_complete => |cc| try grt.std.testing.expectEqual(@as(u16, 0x0C03), cc.opcode),
                else => return error.WrongEvent,
            }

            try grt.std.testing.expectEqual(@as(?Event, null), decode(&.{0x04}));
            try grt.std.testing.expectEqual(@as(?Event, null), decode(&.{}));
            try grt.std.testing.expectEqual(@as(?Event, null), decode(&.{ 0x02, 0x0E, 0x04, 0x01, 0x03, 0x0C, 0x00 }));
        }
    };
    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.run() catch |err| {
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

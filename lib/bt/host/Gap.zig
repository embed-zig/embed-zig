//! LE GAP state machine (Bluetooth Core Spec Vol 3 Part C).
//!
//! Pure state machine — no I/O, no threads. Consumes HCI events,
//! produces HCI command sequences. The Hci coordinator drives this.
//!
//! Usage:
//!   var gap = Gap.init();
//!   gap.startScanning(.{});
//!   while (gap.nextCommand()) |cmd| _ = try transport.write(cmd);
//!   gap.handleEvent(hci_event);

const std = @import("std");
const commands = @import("hci/commands.zig");
const events = @import("hci/events.zig");
const Status = @import("hci/status.zig").Status;

const Gap = @This();

pub const State = enum {
    idle,
    scanning,
    advertising,
    connecting,
    connected,
};

state: State = .idle,
cmd_queue: CmdQueue = .{},
bd_addr: [6]u8 = .{0} ** 6,
addr_known: bool = false,
scanning: bool = false,
advertising: bool = false,
central_connecting: bool = false,
central_link: ?Link = null,
peripheral_link: ?Link = null,
last_status: Status = .success,

pub const Role = enum {
    central,
    peripheral,
};

pub const Link = struct {
    role: Role,
    conn_handle: u16,
    peer_addr: [6]u8,
    peer_addr_type: u8,
    conn_interval: u16,
    conn_latency: u16,
    conn_timeout: u16,
};

const MAX_PENDING_CMDS = 8;
const CmdQueue = struct {
    items: [MAX_PENDING_CMDS]CmdSlot = undefined,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,

    fn push(self: *CmdQueue, data: []const u8) void {
        std.debug.assert(self.count < MAX_PENDING_CMDS);
        std.debug.assert(data.len <= self.items[self.tail].buf.len);
        @memcpy(self.items[self.tail].buf[0..data.len], data);
        self.items[self.tail].len = data.len;
        self.tail = (self.tail + 1) % MAX_PENDING_CMDS;
        self.count += 1;
    }

    fn pop(self: *CmdQueue) ?[]const u8 {
        if (self.count == 0) return null;
        const slot = &self.items[self.head];
        self.head = (self.head + 1) % MAX_PENDING_CMDS;
        self.count -= 1;
        return slot.buf[0..slot.len];
    }

    fn clear(self: *CmdQueue) void {
        self.head = 0;
        self.tail = 0;
        self.count = 0;
    }
};

const CmdSlot = struct {
    buf: [commands.MAX_CMD_LEN]u8 = undefined,
    len: usize = 0,
};

pub fn init() Gap {
    return .{};
}

pub fn startScanning(self: *Gap, config: ScanConfig) void {
    var buf: [commands.MAX_CMD_LEN]u8 = undefined;
    const scan_params = commands.leSetScanParams(&buf, .{
        .active = config.active,
        .interval = config.interval,
        .window = config.window,
        .own_addr_type = .public,
        .filter_policy = .accept_all,
    });
    self.cmd_queue.push(scan_params);

    const scan_enable = commands.leSetScanEnable(&buf, true, config.filter_duplicates);
    self.cmd_queue.push(scan_enable);
    self.scanning = true;
    self.updateState();
}

pub fn stopScanning(self: *Gap) void {
    var buf: [commands.MAX_CMD_LEN]u8 = undefined;
    const cmd = commands.leSetScanEnable(&buf, false, false);
    self.cmd_queue.push(cmd);
    self.scanning = false;
    self.updateState();
}

pub fn startAdvertising(self: *Gap, config: AdvConfig) void {
    var buf: [commands.MAX_CMD_LEN]u8 = undefined;
    const adv_params = commands.leSetAdvParams(&buf, .{
        .interval_min = config.interval_min,
        .interval_max = config.interval_max,
        .adv_type = if (config.connectable) .adv_ind else .adv_nonconn_ind,
        .own_addr_type = .public,
        .peer_addr_type = .public,
        .peer_addr = .{0} ** 6,
        .channel_map = 0x07,
        .filter_policy = .accept_all,
    });
    self.cmd_queue.push(adv_params);

    if (config.adv_data.len > 0) {
        const adv_data = commands.leSetAdvData(&buf, config.adv_data);
        self.cmd_queue.push(adv_data);
    }
    if (config.scan_rsp_data.len > 0) {
        const scan_rsp = commands.leSetScanRspData(&buf, config.scan_rsp_data);
        self.cmd_queue.push(scan_rsp);
    }

    const enable = commands.leSetAdvEnable(&buf, true);
    self.cmd_queue.push(enable);
    self.advertising = true;
    self.updateState();
}

pub fn stopAdvertising(self: *Gap) void {
    var buf: [commands.MAX_CMD_LEN]u8 = undefined;
    const cmd = commands.leSetAdvEnable(&buf, false);
    self.cmd_queue.push(cmd);
    self.advertising = false;
    self.updateState();
}

pub fn connect(self: *Gap, peer_addr: [6]u8, peer_addr_type: commands.PeerAddrType, config: ConnConfig) void {
    var buf: [commands.MAX_CMD_LEN]u8 = undefined;
    const cmd = commands.leCreateConnection(&buf, .{
        .scan_interval = config.scan_interval,
        .scan_window = config.scan_window,
        .filter_policy = .peer_addr,
        .peer_addr_type = peer_addr_type,
        .peer_addr = peer_addr,
        .own_addr_type = .public,
        .conn_interval_min = config.interval_min,
        .conn_interval_max = config.interval_max,
        .max_latency = config.latency,
        .supervision_timeout = config.timeout,
        .min_ce_length = 0,
        .max_ce_length = 0,
    });
    self.cmd_queue.push(cmd);
    self.central_connecting = true;
    self.updateState();
}

pub fn cancelConnect(self: *Gap) void {
    var buf: [commands.MAX_CMD_LEN]u8 = undefined;
    const cmd = commands.leCreateConnectionCancel(&buf);
    self.cmd_queue.push(cmd);
    self.central_connecting = false;
    self.updateState();
}

pub fn disconnect(self: *Gap, conn_handle: u16, reason: u8) void {
    var buf: [commands.MAX_CMD_LEN]u8 = undefined;
    const cmd = commands.disconnect(&buf, conn_handle, reason);
    self.cmd_queue.push(cmd);
}

pub fn readBdAddr(self: *Gap) void {
    var buf: [commands.MAX_CMD_LEN]u8 = undefined;
    const cmd = commands.readBdAddr(&buf);
    self.cmd_queue.push(cmd);
}

pub fn resetController(self: *Gap) void {
    var buf: [commands.MAX_CMD_LEN]u8 = undefined;
    const cmd = commands.reset(&buf);
    self.cmd_queue.clear();
    self.cmd_queue.push(cmd);
    self.scanning = false;
    self.advertising = false;
    self.central_connecting = false;
    self.central_link = null;
    self.peripheral_link = null;
    self.updateState();
}

pub fn nextCommand(self: *Gap) ?[]const u8 {
    return self.cmd_queue.pop();
}

pub fn isScanning(self: *const Gap) bool {
    return self.scanning;
}

pub fn isAdvertising(self: *const Gap) bool {
    return self.advertising;
}

pub fn isConnectingCentral(self: *const Gap) bool {
    return self.central_connecting;
}

pub fn getLink(self: *const Gap, role: Role) ?Link {
    return switch (role) {
        .central => self.central_link,
        .peripheral => self.peripheral_link,
    };
}

pub fn getLinkByHandle(self: *const Gap, conn_handle: u16) ?Link {
    if (self.central_link) |link| {
        if (link.conn_handle == conn_handle) return link;
    }
    if (self.peripheral_link) |link| {
        if (link.conn_handle == conn_handle) return link;
    }
    return null;
}

pub fn getRoleForHandle(self: *const Gap, conn_handle: u16) ?Role {
    if (self.central_link) |link| {
        if (link.conn_handle == conn_handle) return .central;
    }
    if (self.peripheral_link) |link| {
        if (link.conn_handle == conn_handle) return .peripheral;
    }
    return null;
}

pub fn handleEvent(self: *Gap, evt: events.Event) void {
    switch (evt) {
        .command_complete => |cc| self.handleCommandComplete(cc),
        .command_status => |cs| self.last_status = cs.status,
        .le_connection_complete => |lc| {
            self.last_status = lc.status;
            self.central_connecting = false;
            if (lc.status.isSuccess()) {
                const link: Link = .{
                    .role = if (lc.role == 0x00) .central else .peripheral,
                    .conn_handle = lc.conn_handle,
                    .peer_addr = lc.peer_addr,
                    .peer_addr_type = lc.peer_addr_type,
                    .conn_interval = lc.conn_interval,
                    .conn_latency = lc.conn_latency,
                    .conn_timeout = lc.supervision_timeout,
                };
                switch (link.role) {
                    .central => self.central_link = link,
                    .peripheral => self.peripheral_link = link,
                }
            }
            self.updateState();
        },
        .disconnection_complete => |dc| {
            if (self.central_link) |link| {
                if (dc.conn_handle == link.conn_handle) self.central_link = null;
            }
            if (self.peripheral_link) |link| {
                if (dc.conn_handle == link.conn_handle) self.peripheral_link = null;
            }
            self.updateState();
        },
        .le_connection_update_complete => |uc| {
            if (uc.status.isSuccess()) {
                if (self.central_link) |*link| {
                    if (uc.conn_handle == link.conn_handle) {
                        link.conn_interval = uc.conn_interval;
                        link.conn_latency = uc.conn_latency;
                        link.conn_timeout = uc.supervision_timeout;
                    }
                }
                if (self.peripheral_link) |*link| {
                    if (uc.conn_handle == link.conn_handle) {
                        link.conn_interval = uc.conn_interval;
                        link.conn_latency = uc.conn_latency;
                        link.conn_timeout = uc.supervision_timeout;
                    }
                }
            }
        },
        else => {},
    }
}

fn handleCommandComplete(self: *Gap, cc: events.CommandComplete) void {
    self.last_status = cc.status;
    switch (cc.opcode) {
        commands.READ_BD_ADDR => {
            if (cc.status.isSuccess() and cc.return_params.len >= 6) {
                @memcpy(&self.bd_addr, cc.return_params[0..6]);
                self.addr_known = true;
            }
        },
        else => {},
    }
}

fn updateState(self: *Gap) void {
    self.state = if (self.central_connecting)
        .connecting
    else if (self.central_link != null or self.peripheral_link != null)
        .connected
    else if (self.advertising)
        .advertising
    else if (self.scanning)
        .scanning
    else
        .idle;
}

pub const ScanConfig = struct {
    active: bool = true,
    interval: u16 = 0x0010,
    window: u16 = 0x0010,
    filter_duplicates: bool = true,
};

pub const AdvConfig = struct {
    interval_min: u16 = 0x0800,
    interval_max: u16 = 0x0800,
    connectable: bool = true,
    adv_data: []const u8 = &.{},
    scan_rsp_data: []const u8 = &.{},
};

pub const ConnConfig = struct {
    scan_interval: u16 = 0x0060,
    scan_window: u16 = 0x0030,
    interval_min: u16 = 0x0018,
    interval_max: u16 = 0x0028,
    latency: u16 = 0,
    timeout: u16 = 0x00C8,
};

test "bt/unit_tests/host/gap/scan_generates_scan_params_plus_scan_enable_commands" {
    var gap = Gap.init();
    gap.startScanning(.{});
    try std.testing.expectEqual(State.scanning, gap.state);
    try std.testing.expect(gap.isScanning());

    const cmd1 = gap.nextCommand() orelse return error.NoCommand;
    try std.testing.expectEqual(commands.INDICATOR, cmd1[0]);
    try std.testing.expectEqual(commands.LE_SET_SCAN_PARAMS, std.mem.readInt(u16, cmd1[1..3], .little));

    const cmd2 = gap.nextCommand() orelse return error.NoCommand;
    try std.testing.expectEqual(commands.LE_SET_SCAN_ENABLE, std.mem.readInt(u16, cmd2[1..3], .little));

    try std.testing.expectEqual(@as(?[]const u8, null), gap.nextCommand());
}

test "bt/unit_tests/host/gap/stopScanning_generates_scan_disable" {
    var gap = Gap.init();
    gap.startScanning(.{});
    _ = gap.nextCommand();
    _ = gap.nextCommand();

    gap.stopScanning();
    try std.testing.expectEqual(State.idle, gap.state);
    try std.testing.expect(!gap.isScanning());

    const cmd = gap.nextCommand() orelse return error.NoCommand;
    try std.testing.expectEqual(commands.LE_SET_SCAN_ENABLE, std.mem.readInt(u16, cmd[1..3], .little));
    try std.testing.expectEqual(@as(u8, 0), cmd[4]);
}

test "bt/unit_tests/host/gap/advertise_generates_params_plus_data_plus_enable" {
    var gap = Gap.init();
    gap.startAdvertising(.{ .adv_data = &[_]u8{ 0x02, 0x01, 0x06 } });
    try std.testing.expectEqual(State.advertising, gap.state);
    try std.testing.expect(gap.isAdvertising());

    const cmd1 = gap.nextCommand() orelse return error.NoCommand;
    try std.testing.expectEqual(commands.LE_SET_ADV_PARAMS, std.mem.readInt(u16, cmd1[1..3], .little));

    const cmd2 = gap.nextCommand() orelse return error.NoCommand;
    try std.testing.expectEqual(commands.LE_SET_ADV_DATA, std.mem.readInt(u16, cmd2[1..3], .little));

    const cmd3 = gap.nextCommand() orelse return error.NoCommand;
    try std.testing.expectEqual(commands.LE_SET_ADV_ENABLE, std.mem.readInt(u16, cmd3[1..3], .little));
}

test "bt/unit_tests/host/gap/connect_generates_le_create_connection" {
    var gap = Gap.init();
    gap.connect(.{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF }, .public, .{});
    try std.testing.expectEqual(State.connecting, gap.state);
    try std.testing.expect(gap.isConnectingCentral());

    const cmd = gap.nextCommand() orelse return error.NoCommand;
    try std.testing.expectEqual(commands.LE_CREATE_CONNECTION, std.mem.readInt(u16, cmd[1..3], .little));
}

test "bt/unit_tests/host/gap/handleEvent_le_connection_complete_transitions_to_connected" {
    var gap = Gap.init();
    gap.central_connecting = true;
    gap.updateState();
    gap.handleEvent(.{ .le_connection_complete = .{
        .status = .success,
        .conn_handle = 0x0040,
        .role = 0x00,
        .peer_addr_type = 0x00,
        .peer_addr = .{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF },
        .conn_interval = 0x0018,
        .conn_latency = 0,
        .supervision_timeout = 0x00C8,
    } });
    try std.testing.expectEqual(State.connected, gap.state);
    const link = gap.getLink(.central) orelse return error.NoLink;
    try std.testing.expectEqual(@as(u16, 0x0040), link.conn_handle);
}

test "bt/unit_tests/host/gap/handleEvent_disconnection_complete_transitions_to_idle" {
    var gap = Gap.init();
    gap.central_link = .{
        .role = .central,
        .conn_handle = 0x0040,
        .peer_addr = .{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF },
        .peer_addr_type = 0x00,
        .conn_interval = 0x0018,
        .conn_latency = 0,
        .conn_timeout = 0x00C8,
    };
    gap.updateState();
    gap.handleEvent(.{ .disconnection_complete = .{
        .status = .success,
        .conn_handle = 0x0040,
        .reason = .remote_user_terminated,
    } });
    try std.testing.expectEqual(State.idle, gap.state);
}

test "bt/unit_tests/host/gap/scan_and_advertise_can_coexist" {
    var gap = Gap.init();
    gap.startScanning(.{});
    _ = gap.nextCommand();
    _ = gap.nextCommand();
    gap.startAdvertising(.{ .adv_data = &[_]u8{ 0x02, 0x01, 0x06 } });
    try std.testing.expect(gap.isScanning());
    try std.testing.expect(gap.isAdvertising());
    try std.testing.expectEqual(State.advertising, gap.state);
}

test "bt/unit_tests/host/gap/handleEvent_command_complete_READ_BD_ADDR_stores_address" {
    var gap = Gap.init();
    gap.handleEvent(.{ .command_complete = .{
        .num_cmd_packets = 1,
        .opcode = commands.READ_BD_ADDR,
        .status = .success,
        .return_params = &[6]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66 },
    } });
    try std.testing.expect(gap.addr_known);
    try std.testing.expectEqual(@as(u8, 0x11), gap.bd_addr[0]);
    try std.testing.expectEqual(@as(u8, 0x66), gap.bd_addr[5]);
}

test "bt/unit_tests/host/gap/resetController_discards_stale_queued_commands" {
    var gap = Gap.init();
    gap.startScanning(.{});
    gap.resetController();

    const cmd = gap.nextCommand() orelse return error.NoCommand;
    try std.testing.expectEqual(commands.RESET, std.mem.readInt(u16, cmd[1..3], .little));
    try std.testing.expectEqual(@as(?[]const u8, null), gap.nextCommand());
}

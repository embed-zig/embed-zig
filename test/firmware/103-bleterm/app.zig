//! 103-bleterm — BLE Terminal firmware demo.
//!
//! Demonstrates the BLE Term server: registers command handlers,
//! starts BLE advertising, and processes remote shell commands
//! from the bleterm CLI tool.
//!
//! Commands:
//!   sys.info   — return system information
//!   echo       — echo back args
//!   ls         — list files (stub)
//!   slow       — cancellable long-running command

const std = @import("std");
const embed = @import("esp").embed;
const ble = embed.pkg.ble;
const runtime = embed.runtime;
const term = ble.term;
const xfer = ble.xfer;
const gatt = ble.gatt;

// ============================================================================
// GATT Service Table
// ============================================================================

const TERM_SVC: u16 = 0xFFE0;
const TERM_CHR: u16 = 0xFFE1;

const service_table = &[_]gatt.server.ServiceDef{
    gatt.server.Service(TERM_SVC, &.{
        gatt.server.Char(TERM_CHR, .{
            .write = true,
            .write_without_response = true,
            .notify = true,
        }),
    }),
};

// ============================================================================
// Command Handlers
// ============================================================================

fn sysInfoHandler(req: *const term.Request, w: *term.ResponseWriter) void {
    _ = req;
    w.print("firmware: 103-bleterm\nversion: 0.1.0\nzig: 0.15.x", .{});
}

fn echoHandler(req: *const term.Request, w: *term.ResponseWriter) void {
    if (req.args.len > 0) {
        w.write(req.args);
    } else {
        w.write("(empty)");
    }
}

fn lsHandler(req: *const term.Request, w: *term.ResponseWriter) void {
    _ = req;
    w.write("boot.bin\nfirmware.bin\nconfig.json\n");
}

fn slowHandler(req: *const term.Request, w: *term.ResponseWriter) void {
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        if (req.cancel.isCancelled()) {
            w.setError(-1, "cancelled");
            return;
        }
    }
    w.write("done");
}

// ============================================================================
// Firmware Entry Point
// ============================================================================

pub fn run(comptime hw: type, env: anytype) void {
    _ = env;

    const board_spec = @import("board_spec.zig");
    const Board = board_spec.Board(hw);

    const Thread = Board.thread.Type;
    const Mutex = hw.sync.Mutex;
    const Cond = hw.sync.Condition;

    const log: Board.log = .{};
    const allocator = hw.allocator.system;

    // --- 1. Create Host with GATT service table (heap-allocated: ~12KB) ---
    const HostType = ble.host.Host(Mutex, Cond, Thread, hw.ble_hci_spec.Driver, service_table);
    var hci_driver: hw.ble_hci_spec.Driver = .{};
    const host = allocator.create(HostType) catch {
        log.err("alloc host failed");
        return;
    };
    host.initInPlace(&hci_driver, allocator);
    defer {
        host.deinit();
        allocator.destroy(host);
    }

    // --- 2. Create term transport + server (heap-allocated: ~17KB + ~9KB) ---
    const Transport = term.GattTransport(Mutex, Cond);
    const TermServer = term.Server(Thread, Mutex, Cond);

    const notify_ctx = struct {
        host_ptr: *HostType,
        conn_handle: u16,
        attr_handle: u16,

        pub fn notify(ctx: ?*anyopaque, data: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.host_ptr.notify(self.conn_handle, self.attr_handle, data) catch return error.SendFailed;
        }
    };

    var nctx = notify_ctx{
        .host_ptr = host,
        .conn_handle = 0,
        .attr_handle = @TypeOf(host.gatt).getValueHandle(TERM_SVC, TERM_CHR),
    };

    const transport = allocator.create(Transport) catch {
        log.err("alloc transport failed");
        return;
    };
    transport.* = Transport.init(notify_ctx.notify, @ptrCast(&nctx));
    defer {
        transport.deinit();
        allocator.destroy(transport);
    }

    const server = allocator.create(TermServer) catch {
        log.err("alloc server failed");
        return;
    };
    server.* = TermServer.init(transport, .{
        .mtu = 512,
        .spawn_config = .{
            .allocator = allocator,
            .stack_size = 16384,
            .name = "term",
        },
    });
    defer allocator.destroy(server);

    // --- 3. Register command handlers ---
    server.shell.register("sys.info", sysInfoHandler, null) catch {
        log.err("register sys.info failed");
        return;
    };
    server.shell.register("echo", echoHandler, null) catch {
        log.err("register echo failed");
        return;
    };
    server.shell.register("ls", lsHandler, null) catch {
        log.err("register ls failed");
        return;
    };
    server.shell.register("slow", slowHandler, null) catch {
        log.err("register slow failed");
        return;
    };

    // --- 4. Register GATT write handler (pushes into transport rx_queue) ---
    host.gatt.handle(TERM_SVC, TERM_CHR, struct {
        pub fn serve(req: *gatt.server.Request, w: *gatt.server.ResponseWriter) void {
            const tp: *Transport = @ptrCast(@alignCast(req.user_ctx));
            tp.push(req.data) catch {};
            if (req.op == .write) {
                w.ok();
            }
        }
    }.serve, @ptrCast(transport));

    // --- 5. Start Host (HCI init + advertising) ---
    host.start(.{}) catch |err| {
        log.err("host start failed");
        log.err(@errorName(err));
        return;
    };

    // AD Type 0x01 = Flags (LE General Discoverable + BR/EDR Not Supported)
    // AD Type 0x03 = Complete List of 16-bit Service UUIDs
    // AD Type 0x09 = Complete Local Name
    const device_name = "bleterm-103";
    const adv_data = [_]u8{
        0x02, 0x01, 0x06, // Flags
        0x03, 0x03, 0xE0, 0xFF, // Service UUID 0xFFE0 (little-endian)
        device_name.len + 1, 0x09, // Complete Local Name header
    } ++ device_name.*;
    host.startAdvertising(.{
        .adv_data = &adv_data,
        .interval_min = 0x0020, // 20ms
        .interval_max = 0x0040, // 40ms
    }) catch {
        log.err("advertising start failed");
        return;
    };

    log.info("103-bleterm: waiting for connection...");

    // --- 6. Event loop: handle connect/disconnect ---
    while (Board.isRunning()) {
        if (host.nextEvent()) |ev| {
            switch (ev) {
                .connected => |info| {
                    log.info("103-bleterm: connected");
                    nctx.conn_handle = info.conn_handle;
                    transport.reset();
                    server.start() catch {
                        log.err("term server start failed");
                        continue;
                    };
                },
                .disconnected => {
                    log.info("103-bleterm: disconnected");
                    server.stop();
                    transport.reset();
                    host.startAdvertising(.{
                        .adv_data = &adv_data,
                    }) catch {};
                    log.info("103-bleterm: re-advertising");
                },
                else => {},
            }
        }
    }

    server.stop();
    host.stop();
    log.info("103-bleterm: stopped");
}

// ============================================================================
// Tests — mock-based, no real BLE hardware
// ============================================================================

test "103-bleterm: shell register and dispatch" {
    var shell = term.Shell.init();
    try shell.register("sys.info", sysInfoHandler, null);
    try shell.register("echo", echoHandler, null);
    try shell.register("ls", lsHandler, null);

    var cancel = term.CancellationToken{};

    {
        var buf: [512]u8 = undefined;
        const w = shell.dispatch("sys.info", "", 1, 0x40, &cancel, &buf);
        try std.testing.expect(std.mem.indexOf(u8, w.output(), "103-bleterm") != null);
        try std.testing.expectEqual(@as(i8, 0), w.exit_code);
    }

    {
        var buf: [512]u8 = undefined;
        const w = shell.dispatch("echo", "hello world", 2, 0x40, &cancel, &buf);
        try std.testing.expectEqualSlices(u8, "hello world", w.output());
    }

    {
        var buf: [512]u8 = undefined;
        const w = shell.dispatch("ls", "", 3, 0x40, &cancel, &buf);
        try std.testing.expect(std.mem.indexOf(u8, w.output(), "firmware.bin") != null);
    }

    {
        var buf: [512]u8 = undefined;
        const w = shell.dispatch("nonexistent", "", 4, 0x40, &cancel, &buf);
        try std.testing.expectEqual(@as(i8, 1), w.exit_code);
    }
}

test "103-bleterm: cancel handler" {
    var shell = term.Shell.init();
    try shell.register("slow", slowHandler, null);

    var cancel = term.CancellationToken{};
    cancel.cancel();

    var buf: [512]u8 = undefined;
    const w = shell.dispatch("slow", "", 1, 0x40, &cancel, &buf);
    try std.testing.expectEqual(@as(i8, -1), w.exit_code);
    try std.testing.expectEqualSlices(u8, "cancelled", w.err_msg);
}

test "103-bleterm: JSON request parse" {
    const parsed = term.parseRequest("{\"cmd\":\"echo hello\",\"id\":42}") orelse unreachable;
    try std.testing.expectEqualSlices(u8, "echo", parsed.cmd);
    try std.testing.expectEqualSlices(u8, "hello", parsed.args);
    try std.testing.expectEqual(@as(u32, 42), parsed.id);
}

test "103-bleterm: JSON response encode" {
    var buf: [256]u8 = undefined;
    const resp = term.encodeResponse(&buf, 1, "hello", "", 0);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"out\":\"hello\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"exit\":0") != null);
}

test "103-bleterm: full command cycle via xfer mock" {
    const MockTransport = struct {
        const max_data: usize = 16384;
        const max_entries: usize = 256;

        sent_data: [max_data]u8 = undefined,
        sent_lens: [max_entries]usize = undefined,
        sent_count: usize = 0,
        sent_data_size: usize = 0,

        recv_items: [max_entries]RecvItem = undefined,
        recv_count: usize = 0,
        recv_idx: usize = 0,
        recv_data_buf: [max_data]u8 = undefined,
        recv_data_offset: usize = 0,

        const RecvItem = struct { offset: usize, len: usize, is_timeout: bool };

        pub fn send(self: *@This(), data: []const u8) error{Overflow}!void {
            if (self.sent_count >= max_entries or self.sent_data_size + data.len > max_data) return error.Overflow;
            @memcpy(self.sent_data[self.sent_data_size .. self.sent_data_size + data.len], data);
            self.sent_lens[self.sent_count] = data.len;
            self.sent_count += 1;
            self.sent_data_size += data.len;
        }

        pub fn recv(self: *@This(), buf: []u8, timeout_ms: u32) error{Overflow}!?usize {
            _ = timeout_ms;
            if (self.recv_idx >= self.recv_count) return null;
            const item = self.recv_items[self.recv_idx];
            self.recv_idx += 1;
            if (item.is_timeout) return null;
            if (item.len > buf.len) return error.Overflow;
            @memcpy(buf[0..item.len], self.recv_data_buf[item.offset .. item.offset + item.len]);
            return item.len;
        }

        fn scriptRecv(self: *@This(), data: []const u8) void {
            self.recv_items[self.recv_count] = .{
                .offset = self.recv_data_offset,
                .len = data.len,
                .is_timeout = false,
            };
            @memcpy(self.recv_data_buf[self.recv_data_offset .. self.recv_data_offset + data.len], data);
            self.recv_data_offset += data.len;
            self.recv_count += 1;
        }

        fn getSent(self: *const @This(), idx: usize) []const u8 {
            var offset: usize = 0;
            for (self.sent_lens[0..idx]) |l| offset += l;
            return self.sent_data[offset .. offset + self.sent_lens[idx]];
        }
    };

    const mtu: u16 = 50;
    const cmd_json = "{\"cmd\":\"echo hi\",\"id\":1}";

    var cli_mock = MockTransport{};
    cli_mock.scriptRecv(&xfer.start_magic);
    cli_mock.scriptRecv(&xfer.ack_signal);

    var cli_rx = xfer.ReadX(MockTransport).init(&cli_mock, cmd_json, .{
        .mtu = mtu,
        .send_redundancy = 1,
    });
    try cli_rx.run();

    var fw_mock = MockTransport{};
    for (0..cli_mock.sent_count) |i| {
        fw_mock.scriptRecv(cli_mock.getSent(i));
    }

    var recv_buf: [2048]u8 = undefined;
    var fw_wx = xfer.WriteX(MockTransport).init(&fw_mock, &recv_buf, .{ .mtu = mtu });
    const result = try fw_wx.run();

    const parsed = term.parseRequest(result.data) orelse unreachable;
    var shell = term.Shell.init();
    try shell.register("echo", echoHandler, null);

    var cancel = term.CancellationToken{};
    var resp_buf: [256]u8 = undefined;
    const writer = shell.dispatch(parsed.cmd, parsed.args, parsed.id, 0x40, &cancel, &resp_buf);

    var json_buf: [512]u8 = undefined;
    const resp_json = term.encodeResponse(&json_buf, parsed.id, writer.output(), writer.err_msg, writer.exit_code);

    var fw_send = MockTransport{};
    fw_send.scriptRecv(&xfer.start_magic);
    fw_send.scriptRecv(&xfer.ack_signal);

    var fw_rx = xfer.ReadX(MockTransport).init(&fw_send, resp_json, .{
        .mtu = mtu,
        .send_redundancy = 1,
    });
    try fw_rx.run();

    var cli_recv = MockTransport{};
    for (0..fw_send.sent_count) |i| {
        cli_recv.scriptRecv(fw_send.getSent(i));
    }

    var cli_recv_buf: [2048]u8 = undefined;
    var cli_wx = xfer.WriteX(MockTransport).init(&cli_recv, &cli_recv_buf, .{ .mtu = mtu });
    const cli_result = try cli_wx.run();

    try std.testing.expect(std.mem.indexOf(u8, cli_result.data, "\"out\":\"hi\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, cli_result.data, "\"exit\":0") != null);
}

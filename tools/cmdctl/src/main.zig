const std = @import("std");
const builtin = @import("builtin");
const embed = @import("embed");

const usage =
    \\usage:
    \\  cmdctl tcp [--addr 127.0.0.1] [--port 39074] [--exec COMMAND]
    \\  cmdctl serve-tcp [--addr 127.0.0.1] [--port 39074]
    \\  cmdctl serial --port PATH [--baud 115200] [--exec COMMAND]
    \\  cmdctl bt --service UUID --tx UUID --rx UUID [--addr ADDR] [--exec COMMAND]
    \\
;

const Mode = enum {
    tcp,
    serve_tcp,
    serial,
    bt,
};

const Options = struct {
    mode: Mode,
    addr: []const u8 = embed.cmd.desktop_tcp.default_addr,
    port: u16 = embed.cmd.desktop_tcp.default_port,
    serial_port: ?[]const u8 = null,
    baud: u32 = 115200,
    bt_addr: ?[]const u8 = null,
    bt_service: ?[]const u8 = null,
    bt_tx: ?[]const u8 = null,
    bt_rx: ?[]const u8 = null,
    exec: ?[]const u8 = null,
};

pub fn main() !void {
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);

    if (args.len < 2) return usageError();
    const options = try parseArgs(args[1..]);

    switch (options.mode) {
        .tcp => try runTcp(options),
        .serve_tcp => try runTcpServer(options),
        .serial => try runSerial(options),
        .bt => try runBt(options),
    }
}

fn parseArgs(args: []const []const u8) !Options {
    var options: Options = if (std.mem.eql(u8, args[0], "tcp"))
        .{ .mode = .tcp }
    else if (std.mem.eql(u8, args[0], "serve-tcp"))
        .{ .mode = .serve_tcp }
    else if (std.mem.eql(u8, args[0], "serial"))
        .{ .mode = .serial }
    else if (std.mem.eql(u8, args[0], "bt"))
        .{ .mode = .bt }
    else
        return error.InvalidMode;

    var index: usize = 1;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--addr")) {
            const value = try nextArg(args, &index, "--addr");
            if (options.mode == .bt) {
                options.bt_addr = value;
            } else {
                options.addr = value;
            }
        } else if (std.mem.eql(u8, arg, "--port") and (options.mode == .tcp or options.mode == .serve_tcp)) {
            options.port = try parsePort(try nextArg(args, &index, "--port"));
        } else if (std.mem.eql(u8, arg, "--baud")) {
            options.baud = try std.fmt.parseInt(u32, try nextArg(args, &index, "--baud"), 10);
        } else if (std.mem.eql(u8, arg, "--exec")) {
            options.exec = try nextArg(args, &index, "--exec");
        } else if (std.mem.eql(u8, arg, "--service")) {
            options.bt_service = try nextArg(args, &index, "--service");
        } else if (std.mem.eql(u8, arg, "--tx")) {
            options.bt_tx = try nextArg(args, &index, "--tx");
        } else if (std.mem.eql(u8, arg, "--rx")) {
            options.bt_rx = try nextArg(args, &index, "--rx");
        } else if (std.mem.eql(u8, arg, "--port-path") or (std.mem.eql(u8, arg, "--port") and options.mode == .serial)) {
            options.serial_port = try nextArg(args, &index, "--port");
        } else {
            return error.InvalidArgument;
        }
        index += 1;
    }
    return options;
}

fn nextArg(args: []const []const u8, index: *usize, flag: []const u8) ![]const u8 {
    index.* += 1;
    if (index.* >= args.len) {
        std.debug.print("missing value for {s}\n", .{flag});
        return error.MissingArgument;
    }
    return args[index.*];
}

fn parsePort(value: []const u8) !u16 {
    const parsed = try std.fmt.parseInt(u16, value, 10);
    if (parsed == 0) return error.InvalidPort;
    return parsed;
}

fn runTcp(options: Options) !void {
    if (options.exec == null) return runTcpRepl(options);
    var stream = try std.net.tcpConnectToHost(std.heap.page_allocator, options.addr, options.port);
    defer stream.close();
    try runByteStream(&stream, options, false);
}

fn runTcpRepl(options: Options) !void {
    var line_buf: [1024]u8 = undefined;
    while (try readStdinLine(&line_buf)) |line| {
        var stream = try std.net.tcpConnectToHost(std.heap.page_allocator, options.addr, options.port);
        errdefer stream.close();
        try sendCommand(&stream, line);
        try readResponse(&stream, false);
        stream.close();
    }
}

fn runTcpServer(options: Options) !void {
    const address = try std.net.Address.parseIp(options.addr, options.port);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    var registry = embed.cmd.Executor.Registry.init(std.heap.page_allocator);
    defer registry.deinit();
    try embed.cmd.common.registerMinimal(&registry, .{ .version = "cmdctl-serve-tcp" });

    while (true) {
        var conn = try server.accept();
        try serveOne(&conn.stream, registry.executor());
        conn.stream.close();
    }
}

fn runSerial(options: Options) !void {
    const path = options.serial_port orelse return error.MissingSerialPort;
    var file = try std.fs.openFileAbsolute(path, .{ .mode = .read_write });
    defer file.close();
    try configureSerial(&file, options.baud);
    try drainSerial(&file);
    if (options.exec) |command| {
        try sendCommand(&file, command);
        try readSerialResponse(&file, command);
        return;
    }
    try runSerialRepl(&file);
}

fn configureSerial(file: *std.fs.File, baud: u32) !void {
    if (comptime builtin.os.tag == .windows) return error.UnsupportedSerialPlatform;

    const speed = try serialSpeed(baud);
    var term = try std.posix.tcgetattr(file.handle);
    term.iflag = .{};
    term.oflag = .{};
    term.lflag = .{};
    term.cflag.CSIZE = .CS8;
    term.cflag.CREAD = true;
    term.cflag.CLOCAL = true;
    term.cflag.CSTOPB = false;
    term.cflag.PARENB = false;
    term.ispeed = speed;
    term.ospeed = speed;
    term.cc[@intFromEnum(std.posix.V.MIN)] = 0;
    term.cc[@intFromEnum(std.posix.V.TIME)] = 1;
    try std.posix.tcsetattr(file.handle, .FLUSH, term);
}

fn serialSpeed(baud: u32) !std.posix.speed_t {
    return switch (baud) {
        9600 => .B9600,
        19200 => .B19200,
        38400 => .B38400,
        57600 => .B57600,
        115200 => .B115200,
        230400 => .B230400,
        else => error.UnsupportedSerialBaud,
    };
}

fn runBt(options: Options) !void {
    if (comptime builtin.os.tag != .macos) return error.BtKcpHostBackendUnavailable;
    try runBtMacos(options);
}

fn runBtMacos(options: Options) !void {
    const glib = @import("glib");
    const gstd = @import("gstd");
    const core_bluetooth = @import("core_bluetooth");
    const kcp = @import("kcp");

    const service_uuid = try parseUuid16(options.bt_service orelse return error.MissingBtServiceUuid);
    const tx_uuid = try parseUuid16(options.bt_tx orelse return error.MissingBtTxUuid);
    const rx_uuid = try parseUuid16(options.bt_rx orelse return error.MissingBtRxUuid);
    const addr_filter = if (options.bt_addr) |addr| try parseBtAddr(addr) else null;

    const Bt = embed.bt.make(gstd.runtime);
    const Host = Bt.makeHost(core_bluetooth.Host);
    const BtKcp = embed.bt.kcp.make(gstd.runtime, kcp);
    const BtClient = Bt.Client;

    var host = try Host.init(undefined, .{
        .allocator = std.heap.page_allocator,
    });
    defer host.deinit();

    var central = host.central();
    try central.start();
    defer central.stop();

    const BtScanState = ScanState(gstd, glib);
    var scan_state = BtScanState{ .addr_filter = addr_filter };
    central.addEventHook(&scan_state, BtScanState.onEvent);
    defer central.removeEventHook(&scan_state, BtScanState.onEvent);

    try central.startScanning(.{
        .service_uuids = &.{service_uuid},
        .filter_duplicates = false,
    });
    const found = scan_state.wait(10 * glib.time.duration.Second) orelse return error.BtDeviceNotFound;
    central.stopScanning();

    var client = BtClient.init(std.heap.page_allocator);
    defer client.deinit();
    client.bind(central);

    const conn = try client.connect(found.addr, found.addr_type, .{});
    defer client.disconnectConn(conn.info.conn_handle);

    var kcp_client = KcpClient(BtClient){ .client = &client };
    const stream = try BtKcp.client.openStream(std.heap.page_allocator, &kcp_client, conn.info.conn_handle, .{
        .service_uuid = service_uuid,
        .tx_char_uuid = tx_uuid,
        .rx_char_uuid = rx_uuid,
    });
    defer stream.deinit();

    if (options.exec) |command| {
        try sendKcpCommand(stream, command);
        try readKcpResponse(glib, stream);
        return;
    }
    try runKcpRepl(glib, stream);
}

fn runByteStream(stream: anytype, options: Options, stop_after_first_line: bool) !void {
    if (options.exec) |command| {
        try sendCommand(stream, command);
        try readResponse(stream, stop_after_first_line);
        return;
    }
    return runRepl(stream);
}

fn runRepl(stream: anytype) !void {
    var line_buf: [1024]u8 = undefined;
    while (try readStdinLine(&line_buf)) |line| {
        try sendCommand(stream, line);
        try readResponse(stream, true);
    }
}

fn runSerialRepl(file: *std.fs.File) !void {
    var line_buf: [1024]u8 = undefined;
    while (try readStdinLine(&line_buf)) |line| {
        try sendCommand(file, line);
        try readSerialResponse(file, line);
    }
}

fn readStdinLine(out: []u8) !?[]const u8 {
    var len: usize = 0;
    while (len < out.len) {
        var byte: [1]u8 = undefined;
        const n = try std.fs.File.stdin().read(&byte);
        if (n == 0 and len == 0) return null;
        if (n == 0 or byte[0] == '\n') break;
        out[len] = byte[0];
        len += 1;
    }
    if (len == out.len) return error.LineTooLong;
    return out[0..len];
}

fn sendCommand(stream: anytype, command: []const u8) !void {
    try stream.writeAll(command);
    if (command.len == 0 or command[command.len - 1] != '\n') try stream.writeAll("\n");
}

fn readResponse(stream: anytype, stop_after_first_line: bool) !void {
    var buf: [1024]u8 = undefined;
    while (true) {
        const n = try stream.read(&buf);
        if (n == 0) break;
        try std.fs.File.stdout().writeAll(buf[0..n]);
        if (stop_after_first_line and std.mem.indexOfScalar(u8, buf[0..n], '\n') != null) break;
    }
}

fn drainSerial(file: *std.fs.File) !void {
    var poll_fd = std.posix.pollfd{
        .fd = file.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    };
    var buf: [512]u8 = undefined;
    while (try std.posix.poll((&poll_fd)[0..1], 0) > 0) {
        _ = try file.read(&buf);
        poll_fd.revents = 0;
    }
}

fn readSerialResponse(file: *std.fs.File, command: []const u8) !void {
    var raw: [8192]u8 = undefined;
    var len: usize = 0;
    var poll_fd = std.posix.pollfd{
        .fd = file.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    };
    const deadline_ms = std.time.milliTimestamp() + 3000;
    var saw_bytes = false;

    while (std.time.milliTimestamp() < deadline_ms) {
        const timeout_ms: i32 = if (saw_bytes) 250 else 1000;
        const ready = try std.posix.poll((&poll_fd)[0..1], timeout_ms);
        poll_fd.revents = 0;
        if (ready == 0) {
            if (saw_bytes) break;
            continue;
        }
        const n = try file.read(raw[len..]);
        if (n == 0) break;
        len += n;
        saw_bytes = true;
        if (len == raw.len) return error.SerialResponseTooLarge;
    }

    try writeFilteredSerialResponse(raw[0..len], command);
}

fn writeFilteredSerialResponse(raw: []const u8, command: []const u8) !void {
    var offset: usize = 0;
    while (offset <= raw.len) {
        const end = std.mem.indexOfScalarPos(u8, raw, offset, '\n') orelse raw.len;
        var line = std.mem.trim(u8, raw[offset..end], " \t\r");
        line = stripPrompt(line);
        if (line.len != 0 and !std.mem.eql(u8, line, command)) {
            try std.fs.File.stdout().writeAll(line);
            try std.fs.File.stdout().writeAll("\n");
        }
        if (end == raw.len) break;
        offset = end + 1;
    }
}

fn stripPrompt(line: []const u8) []const u8 {
    if (std.mem.eql(u8, line, "cmd>") or std.mem.eql(u8, line, "#")) return "";
    if (std.mem.startsWith(u8, line, "cmd>")) return std.mem.trim(u8, line[4..], " \t");
    if (std.mem.startsWith(u8, line, "#")) return std.mem.trim(u8, line[1..], " \t");
    return line;
}

fn serveOne(stream: *std.net.Stream, executor: embed.cmd.Executor) !void {
    var line_buf: [1024]u8 = undefined;
    const n = try readLine(stream, &line_buf);
    var out = TcpOutput{ .stream = stream };
    const output = embed.cmd.Output.make(TcpOutput).init(&out);
    try embed.cmd.uart.executeLine(executor, line_buf[0..n], output);
}

fn readLine(stream: *std.net.Stream, out: []u8) !usize {
    var len: usize = 0;
    while (len < out.len) {
        var byte: [1]u8 = undefined;
        const n = try stream.read(&byte);
        if (n == 0) break;
        if (byte[0] == '\n') break;
        out[len] = byte[0];
        len += 1;
    }
    return len;
}

const TcpOutput = struct {
    stream: *std.net.Stream,

    pub fn write(self: *TcpOutput, chunk: []const u8) !usize {
        try self.stream.writeAll(chunk);
        return chunk.len;
    }
};

fn usageError() !void {
    try std.fs.File.stderr().writeAll(usage);
    return error.InvalidUsage;
}

fn parseUuid16(value: []const u8) !u16 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    const hex = if (std.mem.startsWith(u8, trimmed, "0x") or std.mem.startsWith(u8, trimmed, "0X"))
        trimmed[2..]
    else
        trimmed;
    if (hex.len == 0 or hex.len > 4) return error.InvalidUuid;
    return std.fmt.parseInt(u16, hex, 16);
}

fn parseBtAddr(value: []const u8) !embed.bt.Central.BdAddr {
    var out: embed.bt.Central.BdAddr = undefined;
    var clean: [12]u8 = undefined;
    var clean_len: usize = 0;
    for (value) |byte| {
        if (byte == ':' or byte == '-' or byte == ' ') continue;
        if (clean_len == clean.len) return error.InvalidBtAddress;
        clean[clean_len] = byte;
        clean_len += 1;
    }
    if (clean_len != clean.len) return error.InvalidBtAddress;
    for (0..6) |i| {
        out[i] = try std.fmt.parseInt(u8, clean[i * 2 .. i * 2 + 2], 16);
    }
    return out;
}

fn ScanState(comptime gstd: type, comptime glib: type) type {
    return struct {
        mutex: gstd.runtime.sync.Mutex = .{},
        cond: gstd.runtime.sync.Condition = .{},
        found: ?embed.bt.Central.AdvReport = null,
        addr_filter: ?embed.bt.Central.BdAddr = null,

        fn onEvent(ctx: ?*anyopaque, event: embed.bt.Central.Event) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            switch (event) {
                .device_found => |report| self.noteFound(report),
                else => {},
            }
        }

        fn noteFound(self: *@This(), report: embed.bt.Central.AdvReport) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.found != null) return;
            if (self.addr_filter) |expected| {
                if (!std.mem.eql(u8, &expected, &report.addr)) return;
            }
            self.found = report;
            self.cond.broadcast();
        }

        fn wait(self: *@This(), timeout: glib.time.duration.Duration) ?embed.bt.Central.AdvReport {
            const deadline_ns = std.time.nanoTimestamp() + @as(i128, @intCast(timeout));
            self.mutex.lock();
            defer self.mutex.unlock();
            while (self.found == null) {
                const remaining_ns = deadline_ns - std.time.nanoTimestamp();
                if (remaining_ns <= 0) return null;
                self.cond.timedWait(&self.mutex, @intCast(remaining_ns)) catch return null;
            }
            return self.found.?;
        }
    };
}

fn KcpClient(comptime BtClient: type) type {
    return struct {
        client: *BtClient,

        pub fn resolveCharacteristic(
            self: *@This(),
            conn_handle: u16,
            service_uuid: u16,
            characteristic_uuid: u16,
        ) BtClient.GattError!BtClient.Characteristic {
            const desc = try self.client.resolveCharacteristic(conn_handle, service_uuid, characteristic_uuid);
            return BtClient.Characteristic.init(self.client, conn_handle, service_uuid, characteristic_uuid, desc);
        }
    };
}

fn sendKcpCommand(stream: anytype, command: []const u8) !void {
    try stream.write(command);
    if (command.len == 0 or command[command.len - 1] != '\n') try stream.write("\n");
}

fn readKcpResponse(comptime glib: type, stream: anytype) !void {
    var buf: [1024]u8 = undefined;
    var saw_bytes = false;
    while (true) {
        const timeout = if (saw_bytes)
            250 * glib.time.duration.MilliSecond
        else
            3 * glib.time.duration.Second;
        const maybe = try stream.readTimeout(&buf, timeout);
        const n = maybe orelse break;
        if (n == 0) break;
        saw_bytes = true;
        try std.fs.File.stdout().writeAll(buf[0..n]);
    }
}

fn runKcpRepl(comptime glib: type, stream: anytype) !void {
    var line_buf: [1024]u8 = undefined;
    while (try readStdinLine(&line_buf)) |line| {
        try sendKcpCommand(stream, line);
        try readKcpResponse(glib, stream);
    }
}

pub fn testParseTcpDefaults() !void {
    const options = try parseArgs(&.{"tcp"});
    try std.testing.expectEqual(Mode.tcp, options.mode);
    try std.testing.expectEqualStrings("127.0.0.1", options.addr);
    try std.testing.expectEqual(@as(u16, 39074), options.port);
}

pub fn testParseServeTcpDefaults() !void {
    const options = try parseArgs(&.{"serve-tcp"});
    try std.testing.expectEqual(Mode.serve_tcp, options.mode);
    try std.testing.expectEqualStrings("127.0.0.1", options.addr);
    try std.testing.expectEqual(@as(u16, 39074), options.port);
}

pub fn testParseSerialExec() !void {
    const options = try parseArgs(&.{ "serial", "--port", "/dev/cu.test", "--exec", "ping" });
    try std.testing.expectEqual(Mode.serial, options.mode);
    try std.testing.expectEqualStrings("/dev/cu.test", options.serial_port.?);
    try std.testing.expectEqualStrings("ping", options.exec.?);
}

pub fn testParseSerialBaud() !void {
    const options = try parseArgs(&.{ "serial", "--port", "/dev/cu.test", "--baud", "230400" });
    try std.testing.expectEqual(@as(u32, 230400), options.baud);
    try std.testing.expectEqual(std.posix.speed_t.B230400, try serialSpeed(options.baud));
    try std.testing.expectError(error.UnsupportedSerialBaud, serialSpeed(12345));
}

pub fn testParseBtAddr() !void {
    const options = try parseArgs(&.{ "bt", "--addr", "AA:BB:CC:DD:EE:FF", "--service", "FEE0", "--tx", "FEE1", "--rx", "FEE2" });
    try std.testing.expectEqual(Mode.bt, options.mode);
    try std.testing.expectEqualStrings("AA:BB:CC:DD:EE:FF", options.bt_addr.?);
    try std.testing.expectEqualStrings("FEE0", options.bt_service.?);
}

pub fn testParseUuid16() !void {
    try std.testing.expectEqual(@as(u16, 0xFEE0), try parseUuid16("FEE0"));
    try std.testing.expectEqual(@as(u16, 0xFEE1), try parseUuid16("0xfee1"));
}

//! **Host-only** DTE smoke over a **real serial device** (POSIX: macOS / Linux).
//!
//! Uses **`std`**-shaped `lib` (host). Invoked from **`test_runner/integration.zig`**, not re-exported
//! from `lib/at.zig`'s `test_runner` namespace, so normal `at` imports stay embed-only.
//!
//! ## Topology
//!
//! | Side | Role | What runs |
//! |------|------|-----------|
//! | **This test (PC)** | **DTE** | `Dte` + POSIX `read`/`write` on `EMBED_AT_SERIAL` |
//! | **ESP32-S3 (firmware)** | **DCE** | Your UART/USB-CDC **AT command loop** |
//!
//! On-wire DCE is **not** `Dce.zig` (that is in-process mock; see `dte_loopback.zig`).
//!
//! ## Environment
//!
//! - **`EMBED_AT_SERIAL`**: e.g. **`/dev/cu.usbmodem*`** (macOS **callout** — required for non-blocking
//!   host I/O). If you pass **`/dev/tty.*`**, this runner **rewrites** it to the matching **`cu`** path
//!   on macOS (`tty` is the call-in side and can **block** `read` even when tests expect timeouts).
//!   Linux: e.g. `/dev/ttyUSB0`. Unset → skip.
//! - **`EMBED_AT_BAUD`**: optional, default `115200`.
//! - **`EMBED_AT_TRANSPORT_TIMEOUT_MS`**: per-`readLine` I/O deadline. Default **8000** ms.
//! - **`EMBED_AT_AT_RETRIES`**: **`AT`** probe attempts after flush (default **4**), **400 ms** apart.
//!   Raise both env vars if the board is slow to boot; lower retries for faster failure when no DCE.

const Dte = @import("../../Dte.zig");
const Transport = @import("../../Transport.zig");
const testing_api = @import("testing");

const std = @import("std");
const builtin = @import("builtin");

pub const Options = struct {
    line_cap: usize = 256,
};

pub fn make(comptime lib: type, comptime opts: Options) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;
            runHostSerial(lib, opts.line_cap, t) catch |err| {
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

/// On Apple platforms, **`/dev/tty.*`** is the *call-in* device: `read()` can **block** waiting on
/// modem / line discipline even when the fd has **`O_NONBLOCK`**, which deadlocks this smoke test.
/// Host DTE should use **`/dev/cu.*`** (callout). We rewrite `tty` → `cu` when the user passes a
/// `tty` path by mistake.
fn darwinCuInsteadOfTty(path_z: [:0]const u8, path_buf: *[std.fs.max_path_bytes:0]u8, t: *testing_api.T) [:0]const u8 {
    if (builtin.os.tag != .macos and builtin.os.tag != .ios) return path_z;
    const tty_prefix = "/dev/tty.";
    if (!std.mem.startsWith(u8, path_z, tty_prefix)) return path_z;
    const tail = path_z[tty_prefix.len..];
    const rewritten = std.fmt.bufPrintZ(path_buf, "/dev/cu.{s}", .{tail}) catch return path_z;
    t.logInfo("dte_serial_host: macOS/iOS: using /dev/cu.* (not tty.*) so reads do not block indefinitely");
    return rewritten;
}

fn runHostSerial(comptime lib: type, comptime line_cap: usize, t: *testing_api.T) !void {
    if (builtin.os.tag == .windows) {
        t.logInfo("skip: dte_serial_host is POSIX-only (macOS/Linux; or use loopback runner)");
        return;
    }

    const path_z = std.posix.getenv("EMBED_AT_SERIAL") orelse {
        t.logInfo("skip: EMBED_AT_SERIAL unset (flash ESP32-S3 DCE firmware, then set e.g. /dev/cu.usbmodem*)");
        return;
    };
    if (path_z.len == 0) {
        t.logInfo("skip: EMBED_AT_SERIAL empty");
        return;
    }

    const baud = parseBaud(std.posix.getenv("EMBED_AT_BAUD")) orelse 115200;
    const transport_ms = parseU32Ms(std.posix.getenv("EMBED_AT_TRANSPORT_TIMEOUT_MS")) orelse 8000;
    const at_retries = parseU32Ms(std.posix.getenv("EMBED_AT_AT_RETRIES")) orelse 4;

    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const path_open = darwinCuInsteadOfTty(path_z, &path_buf, t);

    const fd = try std.posix.openZ(path_open, .{
        .ACCMODE = .RDWR,
        .CLOEXEC = true,
        .NOCTTY = true,
        .NONBLOCK = true,
    }, 0);
    defer std.posix.close(fd);

    try configurePort(fd, baud);
    // Let USB-CDC / driver settle after termios (especially macOS).
    std.Thread.sleep(50 * std.time.ns_per_ms);

    // termios apply must not clear O_NONBLOCK on this platform; reinforce after attribute change.
    const fl = try std.posix.fcntl(fd, std.posix.F.GETFL, 0);
    var o_flags = @as(std.posix.O, @bitCast(@as(u32, @truncate(fl))));
    o_flags.NONBLOCK = true;
    _ = try std.posix.fcntl(fd, std.posix.F.SETFL, @as(usize, @intCast(@as(u32, @bitCast(o_flags)))));

    var serial = Serial{ .fd = fd };
    const transport = Transport.init(&serial);
    const D = Dte.make(lib, line_cap);
    var dte = D.init(transport, .{
        .transport_read_timeout_ms = transport_ms,
        .transport_write_timeout_ms = transport_ms,
        // Boot logs / several URC lines before `OK` need a generous wall budget.
        .command_timeout_ms = 30_000,
    });

    var fin_at: D.Final = undefined;
    var at_failures: u32 = 0;
    while (true) {
        dte.flushRx();
        dte.clearReader();
        fin_at = dte.exchange("AT", .{}) catch |err| switch (err) {
            error.Timeout => {
                at_failures += 1;
                if (at_failures >= at_retries) {
                    logSerialTimeoutHints(t, path_open, serial.rx_total, serial.tx_total, at_retries, transport_ms);
                    return err;
                }
                t.logInfo("dte_serial_host: AT probe timeout; retrying (CDC / app may still be starting)");
                std.Thread.sleep(400 * std.time.ns_per_ms);
                continue;
            },
            else => |e| return e,
        };
        break;
    }
    if (fin_at != .ok) return error.SerialAtNotOk;

    const fin_csq = dte.exchange("AT+CSQ", .{}) catch |err| switch (err) {
        error.Timeout => {
            t.logInfo("AT+CSQ timed out (optional); AT probe succeeded");
            return;
        },
        else => |e| return e,
    };
    if (fin_csq != .ok) return error.SerialCsqNotOk;
}

fn logSerialTimeoutHints(
    t: *testing_api.T,
    path_open: [:0]const u8,
    rx_total: u64,
    tx_total: u64,
    attempts: u32,
    transport_ms: u32,
) void {
    t.logError("dte_serial_host: Timeout after AT probes — no full line ending in OK within per-read budget.");
    t.logInfo("  Opened port (try `picocom -b 115200 <same path>` and type AT + Enter; expect OK).");
    t.logInfof("  Path: {s}", .{path_open});
    t.logInfof("  Stats: tx {d} B, rx {d} B over {d} attempt(s); read deadline/line ≈ {d} ms (EMBED_AT_TRANSPORT_TIMEOUT_MS).", .{
        tx_total, rx_total, attempts, transport_ms,
    });
    t.logInfo("  If rx is 0: wrong USB serial (some boards expose two cu.*), monitor still open, or firmware AT not on this CDC.");
    t.logInfo("  If rx > 0 but still timeout: lines must end with \\n or \\r (see lib/at LineReader).");
}

fn parseBaud(env: ?[:0]const u8) ?u32 {
    const s = env orelse return null;
    if (s.len == 0) return null;
    return std.fmt.parseInt(u32, s, 10) catch null;
}

fn parseU32Ms(env: ?[:0]const u8) ?u32 {
    const v = parseBaud(env) orelse return null;
    if (v == 0) return null;
    return v;
}

const Serial = struct {
    fd: std.posix.fd_t,
    read_deadline_ns: ?i64 = null,
    write_deadline_ns: ?i64 = null,
    rx_total: u64 = 0,
    tx_total: u64 = 0,

    pub fn write(self: *Serial, buf: []const u8) Transport.WriteError!usize {
        var off: usize = 0;
        while (off < buf.len) {
            const deadline = self.write_deadline_ns orelse std.time.nanoTimestamp() + 2 * std.time.ns_per_s;
            const w = std.posix.write(self.fd, buf[off..]) catch |err| switch (err) {
                error.WouldBlock => {
                    if (std.time.nanoTimestamp() > deadline) return error.Timeout;
                    std.Thread.sleep(1 * std.time.ns_per_ms);
                    continue;
                },
                else => return error.HwError,
            };
            if (w == 0) return error.Unexpected;
            self.tx_total += w;
            off += w;
        }
        return buf.len;
    }

    pub fn read(self: *Serial, buf: []u8) Transport.ReadError!usize {
        const deadline = self.read_deadline_ns orelse std.time.nanoTimestamp() + 2 * std.time.ns_per_s;
        while (true) {
            if (std.time.nanoTimestamp() > deadline) return error.Timeout;
            const r = std.posix.read(self.fd, buf) catch |err| switch (err) {
                error.WouldBlock => {
                    std.Thread.sleep(1 * std.time.ns_per_ms);
                    continue;
                },
                else => return error.HwError,
            };
            if (r == 0) {
                // Rare on non-blocking TTY; avoid tight spin with LineReader's read loop.
                std.Thread.sleep(1 * std.time.ns_per_ms);
                continue;
            }
            self.rx_total += r;
            return r;
        }
    }

    pub fn flushRx(self: *Serial) void {
        var scratch: [256]u8 = undefined;
        while (true) {
            const n = std.posix.read(self.fd, &scratch) catch break;
            if (n == 0) break;
            self.rx_total += n;
        }
    }

    pub fn reset(self: *Serial) void {
        _ = self;
    }

    pub fn deinit(self: *Serial) void {
        _ = self;
    }

    pub fn setReadDeadline(self: *Serial, deadline_ns: ?i64) void {
        self.read_deadline_ns = deadline_ns;
    }

    pub fn setWriteDeadline(self: *Serial, deadline_ns: ?i64) void {
        self.write_deadline_ns = deadline_ns;
    }
};

fn configurePort(fd: std.posix.fd_t, baud: u32) !void {
    var tty = try std.posix.tcgetattr(fd);

    tty.lflag.ECHO = false;
    tty.lflag.ICANON = false;
    tty.lflag.ISIG = false;
    tty.lflag.IEXTEN = false;
    tty.iflag.IXON = false;
    tty.iflag.IXOFF = false;
    tty.iflag.ICRNL = false;
    tty.iflag.INLCR = false;
    tty.iflag.IGNCR = false;
    tty.oflag.OPOST = false;

    tty.cflag.CSIZE = .CS8;
    tty.cflag.CREAD = true;
    tty.cflag.CLOCAL = true;
    tty.cflag.PARENB = false;
    tty.cflag.CSTOPB = false;

    tty.cc[@intFromEnum(std.posix.V.MIN)] = 0;
    tty.cc[@intFromEnum(std.posix.V.TIME)] = 0;

    if (@hasField(std.posix.termios, "ispeed")) {
        const sp = baudToSpeed(baud) catch return error.UnsupportedBaud;
        tty.ispeed = sp;
        tty.ospeed = sp;
    }

    // Flush queued RX/TX while applying attrs (matches common serial-open practice on macOS/Linux).
    try std.posix.tcsetattr(fd, .FLUSH, tty);
}

fn baudToSpeed(baud: u32) !std.posix.speed_t {
    return switch (baud) {
        9600 => .B9600,
        19200 => .B19200,
        38400 => .B38400,
        57600 => .B57600,
        115200 => .B115200,
        230400 => .B230400,
        460800 => if (@hasField(std.posix.speed_t, "B460800")) .B460800 else return error.UnsupportedBaud,
        921600 => if (@hasField(std.posix.speed_t, "B921600")) .B921600 else return error.UnsupportedBaud,
        else => return error.UnsupportedBaud,
    };
}

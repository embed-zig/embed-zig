//! **DTE** (Data Terminal Equipment) — host / MCU side talking to a modem (**DCE**) over
//! [`Transport`](Transport.zig).
//!
//! Thin product-facing wrapper around [`Session`](Session.zig): same `exchange` / raw I/O,
//! with a **`comptime`** check that `lib` exposes **`time.milliTimestamp`** for deadlines.

const SessionMod = @import("Session.zig");
const Transport = @import("Transport.zig");

/// Build a DTE handle type for injected `lib` (e.g. `embed` / board namespace) and max line length
/// `line_cap` (must match how you size `Session` / `LineReader` elsewhere).
pub fn make(comptime lib: type, comptime line_cap: usize) type {
    comptime {
        _ = lib.time.milliTimestamp;
    }

    const SessionType = SessionMod.make(lib, line_cap);

    return struct {
        const Self = @This();

        /// Line-mode session: use for `readLine`, `reader`, `transport`, `config`, or advanced flows.
        session: SessionType,

        pub const Config = SessionType.Config;
        pub const Final = SessionType.Final;
        pub const ExchangeOptions = SessionType.ExchangeOptions;
        pub const ExchangeError = SessionType.ExchangeError;

        pub fn init(transport: Transport, config: Config) Self {
            return .{ .session = SessionType.init(transport, config) };
        }

        pub fn exchange(self: *Self, cmd: []const u8, ex: ExchangeOptions) ExchangeError!Final {
            return self.session.exchange(cmd, ex);
        }

        pub fn flushRx(self: *Self) void {
            self.session.flushRx();
        }

        pub fn clearReader(self: *Self) void {
            self.session.clearReader();
        }

        pub fn writeRaw(self: *Self, data: []const u8) Transport.WriteError!void {
            return self.session.writeRaw(data);
        }

        pub fn readExact(self: *Self, buf: []u8) Transport.ReadError!void {
            return self.session.readExact(buf);
        }
    };
}

const testing_api = @import("testing");

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const TestCase = struct {
        fn testDelegatesExchange() !void {
            const std = @import("std");
            const testing = std.testing;

            const Lib = struct {
                pub const mem = @import("embed").mem;
                pub const time = struct {
                    pub fn milliTimestamp() i64 {
                        return std.time.milliTimestamp();
                    }
                };
            };

            const Impl = struct {
                data: []const u8,
                pos: usize = 0,
                pub fn read(self: *@This(), buf: []u8) Transport.ReadError!usize {
                    if (self.pos >= self.data.len) return 0;
                    const n = @min(buf.len, self.data.len - self.pos);
                    @memcpy(buf[0..n], self.data[self.pos..][0..n]);
                    self.pos += n;
                    return n;
                }
                pub fn write(_: *@This(), buf: []const u8) Transport.WriteError!usize {
                    return buf.len;
                }
                pub fn flushRx(_: *@This()) void {}
                pub fn reset(_: *@This()) void {}
                pub fn deinit(_: *@This()) void {}
                pub fn setReadDeadline(_: *@This(), _: ?i64) void {}
                pub fn setWriteDeadline(_: *@This(), _: ?i64) void {}
            };

            var back = Impl{ .data = "OK\r\n" };
            const transport = Transport.init(&back);
            const D = make(Lib, 64);
            var dte = D.init(transport, .{ .append_crlf = false });

            const fin = try dte.exchange("AT", .{});
            try testing.expectEqual(D.Final.ok, fin);
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

            TestCase.testDelegatesExchange() catch |err| {
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

//! Channel contract — typed, bounded, multi-producer/multi-consumer.
//!
//! Usage:
//!   const sync = @import("sync");
//!   const Channel = sync.Channel(std, platform.ChannelFactory);
//!   const IntChan = Channel(u32);
//!   var ch = try IntChan.make(allocator, 16);
//!   defer ch.deinit();
//!   try ch.send(42);
//!   const result = try ch.recv();

const stdz = @import("stdz");
const testing_api = @import("testing");
const time_mod = @import("time");

pub fn SendResult() type {
    return struct { ok: bool };
}

pub fn RecvResult(comptime T: type) type {
    return struct { value: T, ok: bool };
}

pub const ChannelType = @TypeOf(struct {
    fn impl(comptime T: type) type {
        _ = T;
        unreachable;
    }
}.impl);

pub const FactoryType = @TypeOf(struct {
    fn factory(comptime std: type) ChannelType {
        _ = std;
        unreachable;
    }
}.factory);

/// Construct a sealed Channel type factory from a platform Impl.
///
/// Impl must be: `ChannelType`
/// A higher-order platform factory should be: `FactoryType`
/// The returned factory produces a type for a given T that must provide:
///   fn init(Allocator, usize) !Ch
///   fn deinit(*Ch) void
///   fn close(*Ch) void
///   fn send(*Ch, T) anyerror!SendResult()
///   fn sendTimeout(*Ch, T, time.duration.Duration) anyerror!SendResult()
///   fn recv(*Ch) anyerror!RecvResult(T)
///   fn recvTimeout(*Ch, time.duration.Duration) anyerror!RecvResult(T)
pub fn make(comptime impl: ChannelType) ChannelType {
    return struct {
        fn factory(comptime T: type) type {
            const Ch = impl(T);

            comptime {
                _ = @as(*const fn (*Ch, T) anyerror!SendResult(), &Ch.send);
                _ = @as(*const fn (*Ch, T, time_mod.duration.Duration) anyerror!SendResult(), &Ch.sendTimeout);
                _ = @as(*const fn (*Ch) anyerror!RecvResult(T), &Ch.recv);
                _ = @as(*const fn (*Ch, time_mod.duration.Duration) anyerror!RecvResult(T), &Ch.recvTimeout);
                _ = @as(*const fn (*Ch) void, &Ch.close);
                _ = @as(*const fn (*Ch) void, &Ch.deinit);
                _ = @as(*const fn (stdz.mem.Allocator, usize) anyerror!Ch, &Ch.init);
            }

            return struct {
                ch: Ch,

                const Self = @This();

                pub fn make(allocator: stdz.mem.Allocator, capacity: usize) !Self {
                    return .{ .ch = try Ch.init(allocator, capacity) };
                }

                pub fn deinit(self: *Self) void {
                    self.ch.deinit();
                }

                pub fn close(self: *Self) void {
                    self.ch.close();
                }

                pub fn send(self: *Self, value: T) !SendResult() {
                    return self.ch.send(value);
                }

                pub fn sendTimeout(self: *Self, value: T, timeout: time_mod.duration.Duration) !SendResult() {
                    return self.ch.sendTimeout(value, timeout);
                }

                pub fn recv(self: *Self) !RecvResult(T) {
                    return self.ch.recv();
                }

                pub fn recvTimeout(self: *Self, timeout: time_mod.duration.Duration) !RecvResult(T) {
                    return self.ch.recvTimeout(timeout);
                }
            };
        }
    }.factory;
}

pub fn TestRunner(comptime std: type) testing_api.TestRunner {
    const TestCase = struct {
        fn run() !void {
            const FakeChannelFactory: ChannelType = struct {
                fn make(comptime T: type) type {
                    return struct {
                        slot: ?T = null,
                        closed: bool = false,
                        init_capacity: usize = 0,
                        last_send_timeout: ?time_mod.duration.Duration = null,

                        pub fn init(allocator: stdz.mem.Allocator, capacity: usize) !@This() {
                            _ = allocator;
                            return .{ .init_capacity = capacity };
                        }

                        pub fn deinit(self: *@This()) void {
                            self.* = undefined;
                        }

                        pub fn close(self: *@This()) void {
                            self.closed = true;
                        }

                        pub fn send(self: *@This(), value: T) !SendResult() {
                            if (self.closed) return .{ .ok = false };
                            self.slot = value;
                            return .{ .ok = true };
                        }

                        pub fn sendTimeout(self: *@This(), value: T, timeout: time_mod.duration.Duration) !SendResult() {
                            self.last_send_timeout = timeout;
                            return self.send(value);
                        }

                        pub fn recv(self: *@This()) !RecvResult(T) {
                            if (self.slot) |value| {
                                self.slot = null;
                                return .{ .value = value, .ok = true };
                            }
                            return .{ .value = undefined, .ok = false };
                        }

                        pub fn recvTimeout(self: *@This(), _: time_mod.duration.Duration) !RecvResult(T) {
                            return self.recv();
                        }
                    };
                }
            }.make;
            const FakePlatformFactory: FactoryType = struct {
                fn make(comptime platform_lib: type) ChannelType {
                    _ = platform_lib;
                    return FakeChannelFactory;
                }
            }.make;

            comptime {
                _ = @as(ChannelType, FakeChannelFactory);
                _ = @as(FactoryType, FakePlatformFactory);
            }

            const BoundChannel = make(FakeChannelFactory);
            const U32Channel = BoundChannel(u32);

            var ch = try U32Channel.make(std.testing.allocator, 7);
            defer ch.deinit();

            try std.testing.expectEqual(@as(usize, 7), ch.ch.init_capacity);

            const send_ok = try ch.send(42);
            try std.testing.expect(send_ok.ok);

            const send_timeout_ok = try ch.sendTimeout(24, 11 * time_mod.duration.MilliSecond);
            try std.testing.expect(send_timeout_ok.ok);
            try std.testing.expectEqual(@as(?time_mod.duration.Duration, 11 * time_mod.duration.MilliSecond), ch.ch.last_send_timeout);

            const recv_ok = try ch.recv();
            try std.testing.expect(recv_ok.ok);
            try std.testing.expectEqual(@as(u32, 24), recv_ok.value);

            ch.close();
            const send_closed = try ch.send(99);
            try std.testing.expect(!send_closed.ok);

            const recv_closed = try ch.recv();
            try std.testing.expect(!recv_closed.ok);

            const recv_timeout_closed = try ch.recvTimeout(10 * time_mod.duration.MilliSecond);
            try std.testing.expect(!recv_timeout_closed.ok);
        }
    };
    const Runner = struct {
        pub fn init(self: *@This(), allocator: std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.run() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };
    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}

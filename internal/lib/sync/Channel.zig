//! Channel contract — typed, bounded, multi-producer/multi-consumer.
//!
//! Usage:
//!   const sync = @import("sync");
//!   const Channel = sync.Channel(lib, platform.ChannelFactory);
//!   const IntChan = Channel(u32);
//!   var ch = try IntChan.make(allocator, 16);
//!   defer ch.deinit();
//!   try ch.send(42);
//!   const result = try ch.recv();

const embed = @import("embed");
const testing_api = @import("testing");

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
    fn factory(comptime lib: type) ChannelType {
        _ = lib;
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
///   fn sendTimeout(*Ch, T, u32) anyerror!SendResult()
///   fn recv(*Ch) anyerror!RecvResult(T)
///   fn recvTimeout(*Ch, u32) anyerror!RecvResult(T)
pub fn make(comptime impl: ChannelType) ChannelType {
    return struct {
        fn factory(comptime T: type) type {
            const Ch = impl(T);

            comptime {
                _ = @as(*const fn (*Ch, T) anyerror!SendResult(), &Ch.send);
                _ = @as(*const fn (*Ch, T, u32) anyerror!SendResult(), &Ch.sendTimeout);
                _ = @as(*const fn (*Ch) anyerror!RecvResult(T), &Ch.recv);
                _ = @as(*const fn (*Ch, u32) anyerror!RecvResult(T), &Ch.recvTimeout);
                _ = @as(*const fn (*Ch) void, &Ch.close);
                _ = @as(*const fn (*Ch) void, &Ch.deinit);
                _ = @as(*const fn (embed.mem.Allocator, usize) anyerror!Ch, &Ch.init);
            }

            return struct {
                ch: Ch,

                const Self = @This();

                pub fn make(allocator: embed.mem.Allocator, capacity: usize) !Self {
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

                pub fn sendTimeout(self: *Self, value: T, timeout_ms: u32) !SendResult() {
                    return self.ch.sendTimeout(value, timeout_ms);
                }

                pub fn recv(self: *Self) !RecvResult(T) {
                    return self.ch.recv();
                }

                pub fn recvTimeout(self: *Self, timeout_ms: u32) !RecvResult(T) {
                    return self.ch.recvTimeout(timeout_ms);
                }
            };
        }
    }.factory;
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const TestCase = struct {
        fn run() !void {
            const FakeChannelFactory: ChannelType = struct {
                fn make(comptime T: type) type {
                    return struct {
                        slot: ?T = null,
                        closed: bool = false,
                        init_capacity: usize = 0,
                        last_send_timeout_ms: ?u32 = null,

                        pub fn init(allocator: embed.mem.Allocator, capacity: usize) !@This() {
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

                        pub fn sendTimeout(self: *@This(), value: T, timeout_ms: u32) !SendResult() {
                            self.last_send_timeout_ms = timeout_ms;
                            return self.send(value);
                        }

                        pub fn recv(self: *@This()) !RecvResult(T) {
                            if (self.slot) |value| {
                                self.slot = null;
                                return .{ .value = value, .ok = true };
                            }
                            return .{ .value = undefined, .ok = false };
                        }

                        pub fn recvTimeout(self: *@This(), _: u32) !RecvResult(T) {
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

            var ch = try U32Channel.make(lib.testing.allocator, 7);
            defer ch.deinit();

            try lib.testing.expectEqual(@as(usize, 7), ch.ch.init_capacity);

            const send_ok = try ch.send(42);
            try lib.testing.expect(send_ok.ok);

            const send_timeout_ok = try ch.sendTimeout(24, 11);
            try lib.testing.expect(send_timeout_ok.ok);
            try lib.testing.expectEqual(@as(?u32, 11), ch.ch.last_send_timeout_ms);

            const recv_ok = try ch.recv();
            try lib.testing.expect(recv_ok.ok);
            try lib.testing.expectEqual(@as(u32, 24), recv_ok.value);

            ch.close();
            const send_closed = try ch.send(99);
            try lib.testing.expect(!send_closed.ok);

            const recv_closed = try ch.recv();
            try lib.testing.expect(!recv_closed.ok);

            const recv_timeout_closed = try ch.recvTimeout(10);
            try lib.testing.expect(!recv_timeout_closed.ok);
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

            TestCase.run() catch |err| {
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

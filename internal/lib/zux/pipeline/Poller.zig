const stdz = @import("stdz");
const Emitter = @import("Emitter.zig");
const testing_api = @import("testing");

const Poller = @This();

impl: *anyopaque,
vtable: *const VTable,
type_id: *const anyopaque,

fn TypeIdHolder(comptime T: type) type {
    return struct {
        comptime _phantom: type = T,
        var id: u8 = 0;
    };
}

fn typeId(comptime T: type) *const anyopaque {
    return @ptrCast(&TypeIdHolder(T).id);
}

pub const default_poll_interval_ns: u64 = 10 * stdz.time.ns_per_ms;

pub const Config = struct {
    poll_interval_ns: u64 = default_poll_interval_ns,
    spawn_config: stdz.Thread.SpawnConfig = .{},
};

pub const VTable = struct {
    bindOutput: *const fn (poller: *Poller, out: Emitter) void,
    start: *const fn (poller: *Poller, config: Config) anyerror!void,
    stop: *const fn (poller: *Poller) void,
    deinit: *const fn (poller: *Poller) void,
};

pub fn as(self: Poller, comptime T: type) error{TypeMismatch}!*T {
    if (self.type_id == typeId(T)) return @ptrCast(@alignCast(self.impl));
    return error.TypeMismatch;
}

pub fn bindOutput(self: *Poller, out: Emitter) void {
    self.vtable.bindOutput(self, out);
}

pub fn start(self: *Poller, config: Config) !void {
    try self.vtable.start(self, config);
}

pub fn stop(self: *Poller) void {
    self.vtable.stop(self);
}

pub fn deinit(self: *Poller) void {
    self.vtable.deinit(self);
}

pub fn init(comptime T: type, impl: *T) Poller {
    comptime {
        _ = @as(*const fn (*T, Emitter) void, &T.bindOutput);
        _ = @as(*const fn (*T, Config) anyerror!void, &T.start);
        _ = @as(*const fn (*T) void, &T.stop);
        _ = @as(*const fn (*T) void, &T.deinit);
    }

    const gen = struct {
        fn bindOutputFn(poller: *Poller, out: Emitter) void {
            const typed: *T = @ptrCast(@alignCast(poller.impl));
            typed.bindOutput(out);
        }

        fn startFn(poller: *Poller, config: Config) anyerror!void {
            const typed: *T = @ptrCast(@alignCast(poller.impl));
            try typed.start(config);
        }

        fn stopFn(poller: *Poller) void {
            const typed: *T = @ptrCast(@alignCast(poller.impl));
            typed.stop();
        }

        fn deinitFn(poller: *Poller) void {
            const typed: *T = @ptrCast(@alignCast(poller.impl));
            typed.deinit();
        }

        const vtable = VTable{
            .bindOutput = bindOutputFn,
            .start = startFn,
            .stop = stopFn,
            .deinit = deinitFn,
        };
    };

    return .{
        .impl = @ptrCast(impl),
        .vtable = &gen.vtable,
        .type_id = typeId(T),
    };
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const TestCase = struct {
        fn initBindStartStopAndDeinit(testing: anytype) !void {
            const Impl = struct {
                bound: bool = false,
                started: bool = false,
                stopped: bool = false,
                deinited: bool = false,
                last_poll_interval_ns: u64 = 0,

                pub fn bindOutput(self: *@This(), _: Emitter) void {
                    self.bound = true;
                }

                pub fn start(self: *@This(), config: Config) !void {
                    self.started = true;
                    self.last_poll_interval_ns = config.poll_interval_ns;
                }

                pub fn stop(self: *@This()) void {
                    self.stopped = true;
                }

                pub fn deinit(self: *@This()) void {
                    self.deinited = true;
                }
            };

            const Sink = struct {
                pub fn emit(_: *@This(), _: @import("Message.zig")) !void {}
            };

            var impl = Impl{};
            var sink = Sink{};
            var poller = Poller.init(Impl, &impl);

            try testing.expect((try poller.as(Impl)) == &impl);
            try testing.expectError(error.TypeMismatch, poller.as(struct { x: u8 }));

            poller.bindOutput(Emitter.init(&sink));
            try poller.start(.{});
            poller.stop();
            poller.deinit();

            try testing.expect(impl.bound);
            try testing.expect(impl.started);
            try testing.expect(impl.stopped);
            try testing.expect(impl.deinited);
            try testing.expectEqual(default_poll_interval_ns, impl.last_poll_interval_ns);
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
            const testing = lib.testing;

            TestCase.initBindStartStopAndDeinit(testing) catch |err| {
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

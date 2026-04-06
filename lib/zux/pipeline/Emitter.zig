const Message = @import("Message.zig");
const testing_api = @import("testing");

const Emitter = @This();

ctx: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    emit: *const fn (ctx: *anyopaque, message: Message) anyerror!void,
};

pub fn emit(self: Emitter, message: Message) !void {
    return self.vtable.emit(self.ctx, message);
}

pub fn init(pointer: anytype) Emitter {
    const Ptr = @TypeOf(pointer);
    const info = @typeInfo(Ptr);
    if (info != .pointer or info.pointer.size != .one)
        @compileError("Emitter.init expects a single-item pointer");

    const Impl = info.pointer.child;

    const gen = struct {
        fn emitFn(ctx: *anyopaque, message: Message) anyerror!void {
            const self: *Impl = @ptrCast(@alignCast(ctx));
            try self.emit(message);
        }

        const vtable = VTable{
            .emit = emitFn,
        };
    };

    return .{
        .ctx = pointer,
        .vtable = &gen.vtable,
    };
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const TestCase = struct {
        fn initAndEmit(testing: anytype) !void {
            const Impl = struct {
                called: bool = false,
                last_timestamp_ns: i128 = 0,

                pub fn emit(self: *@This(), message: Message) !void {
                    self.called = true;
                    self.last_timestamp_ns = message.timestamp_ns;
                }
            };

            var impl = Impl{};
            const emitter = Emitter.init(&impl);
            try emitter.emit(.{
                .origin = .source,
                .timestamp_ns = 9,
                .body = .{
                    .raw_single_button = .{
                        .source_id = 1,
                        .pressed = true,
                    },
                },
            });

            try testing.expect(impl.called);
            try testing.expectEqual(@as(i128, 9), impl.last_timestamp_ns);
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

            TestCase.initAndEmit(testing) catch |err| {
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

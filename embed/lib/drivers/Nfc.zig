//! Nfc — NFC reader contracts and chip drivers.

const glib = @import("glib");

pub const io = @import("nfc/io.zig");
pub const Fm175xx = @import("nfc/fm175xx.zig");

pub const max_uid_len: usize = 10;
pub const max_payload_len: usize = 256;

pub const CardType = enum {
    unknown,
    ntag,
    ndef,
};

pub const Update = struct {
    source_id: u32,
    uid: []const u8,
    payload: ?[]const u8 = null,
    card_type: CardType,
};

pub const CallbackFn = *const fn (ctx: *const anyopaque, update: Update) void;

pub const Reader = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        setEventCallback: *const fn (ptr: *anyopaque, ctx: *const anyopaque, emit_fn: CallbackFn) void,
        clearEventCallback: *const fn (ptr: *anyopaque) void,
    };

    pub fn init(pointer: anytype) Reader {
        const Ptr = @TypeOf(pointer);
        const info = @typeInfo(Ptr);
        if (info != .pointer or info.pointer.size != .one)
            @compileError("nfc.Reader.init expects a single-item pointer");

        const Impl = info.pointer.child;

        const gen = struct {
            fn setEventCallbackFn(ptr: *anyopaque, ctx: *const anyopaque, emit_fn: CallbackFn) void {
                const self: *Impl = @ptrCast(@alignCast(ptr));
                self.setEventCallback(ctx, emit_fn);
            }

            fn clearEventCallbackFn(ptr: *anyopaque) void {
                const self: *Impl = @ptrCast(@alignCast(ptr));
                self.clearEventCallback();
            }

            const vtable = VTable{
                .setEventCallback = setEventCallbackFn,
                .clearEventCallback = clearEventCallbackFn,
            };
        };

        return .{
            .ptr = pointer,
            .vtable = &gen.vtable,
        };
    }

    pub fn fromFm175xx(pointer: *Fm175xx) Reader {
        const gen = struct {
            fn setEventCallbackFn(_: *anyopaque, _: *const anyopaque, _: CallbackFn) void {
                @panic("drivers.nfc.Reader.fromFm175xx requires a higher-level NFC event adapter");
            }

            fn clearEventCallbackFn(_: *anyopaque) void {}

            const vtable = VTable{
                .setEventCallback = setEventCallbackFn,
                .clearEventCallback = clearEventCallbackFn,
            };
        };

        return .{
            .ptr = @ptrCast(pointer),
            .vtable = &gen.vtable,
        };
    }

    pub fn setEventCallback(self: Reader, ctx: *const anyopaque, emit_fn: CallbackFn) void {
        self.vtable.setEventCallback(self.ptr, ctx, emit_fn);
    }

    pub fn clearEventCallback(self: Reader) void {
        self.vtable.clearEventCallback(self.ptr);
    }
};

pub fn TestRunner(comptime lib: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn initSetsAndClearsEventCallback(testing: anytype) !void {
            const Impl = struct {
                receiver_ctx: ?*const anyopaque = null,
                emit_fn: ?CallbackFn = null,

                pub fn setEventCallback(self: *@This(), ctx: *const anyopaque, emit_fn: CallbackFn) void {
                    self.receiver_ctx = ctx;
                    self.emit_fn = emit_fn;
                }

                pub fn clearEventCallback(self: *@This()) void {
                    self.receiver_ctx = null;
                    self.emit_fn = null;
                }
            };

            var impl = Impl{};
            const reader = Reader.init(&impl);
            const callback_ctx: usize = 0x1234;
            const callback = struct {
                fn emitFn(_: *const anyopaque, _: Update) void {}
            }.emitFn;

            reader.setEventCallback(@ptrFromInt(callback_ctx), callback);
            try testing.expectEqual(@as(?*const anyopaque, @ptrFromInt(callback_ctx)), impl.receiver_ctx);
            try testing.expect(impl.emit_fn != null);

            reader.clearEventCallback();
            try testing.expect(impl.receiver_ctx == null);
            try testing.expect(impl.emit_fn == null);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.initSetsAndClearsEventCallback(lib.testing) catch |err| {
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
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}

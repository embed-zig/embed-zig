//! nfc — NFC reader contracts and protocol-level IO seams.

const glib = @import("glib");

pub const io = @import("nfc/io.zig");
pub const ndef = @import("nfc/ndef.zig");
pub const TypeA = io.TypeA;

pub const test_runner = struct {
    pub const unit = struct {
        pub fn make(comptime grt: type) glib.testing.TestRunner {
            return TestRunner(grt);
        }
    };
};

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
    present: bool = true,
};

pub const CallbackFn = *const fn (ctx: *const anyopaque, update: Update) void;

pub const ScanConfig = struct {
    interval_ms: u32 = 200,
    read_payload: bool = false,
};

pub const ScanError = error{
    Busy,
    Unsupported,
    Unexpected,
};

pub const Reader = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        startScan: *const fn (ptr: *anyopaque, config: ScanConfig) ScanError!void,
        stopScan: *const fn (ptr: *anyopaque) void,
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
            fn startScanFn(ptr: *anyopaque, config: ScanConfig) ScanError!void {
                const self: *Impl = @ptrCast(@alignCast(ptr));
                return self.startScan(config);
            }

            fn stopScanFn(ptr: *anyopaque) void {
                const self: *Impl = @ptrCast(@alignCast(ptr));
                self.stopScan();
            }

            fn setEventCallbackFn(ptr: *anyopaque, ctx: *const anyopaque, emit_fn: CallbackFn) void {
                const self: *Impl = @ptrCast(@alignCast(ptr));
                self.setEventCallback(ctx, emit_fn);
            }

            fn clearEventCallbackFn(ptr: *anyopaque) void {
                const self: *Impl = @ptrCast(@alignCast(ptr));
                self.clearEventCallback();
            }

            const vtable = VTable{
                .startScan = startScanFn,
                .stopScan = stopScanFn,
                .setEventCallback = setEventCallbackFn,
                .clearEventCallback = clearEventCallbackFn,
            };
        };

        return .{
            .ptr = pointer,
            .vtable = &gen.vtable,
        };
    }

    pub fn startScan(self: Reader, config: ScanConfig) ScanError!void {
        return self.vtable.startScan(self.ptr, config);
    }

    pub fn stopScan(self: Reader) void {
        self.vtable.stopScan(self.ptr);
    }

    pub fn setEventCallback(self: Reader, ctx: *const anyopaque, emit_fn: CallbackFn) void {
        self.vtable.setEventCallback(self.ptr, ctx, emit_fn);
    }

    pub fn clearEventCallback(self: Reader) void {
        self.vtable.clearEventCallback(self.ptr);
    }
};

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn initSetsAndClearsEventCallback() !void {
            const Impl = struct {
                receiver_ctx: ?*const anyopaque = null,
                emit_fn: ?CallbackFn = null,
                scanning: bool = false,
                last_scan_config: ScanConfig = .{},

                pub fn startScan(self: *@This(), config: ScanConfig) ScanError!void {
                    self.scanning = true;
                    self.last_scan_config = config;
                }

                pub fn stopScan(self: *@This()) void {
                    self.scanning = false;
                }

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

            try reader.startScan(.{ .interval_ms = 50, .read_payload = true });
            try grt.std.testing.expect(impl.scanning);
            try grt.std.testing.expectEqual(@as(u32, 50), impl.last_scan_config.interval_ms);
            try grt.std.testing.expect(impl.last_scan_config.read_payload);

            reader.setEventCallback(@ptrFromInt(callback_ctx), callback);
            try grt.std.testing.expectEqual(@as(?*const anyopaque, @ptrFromInt(callback_ctx)), impl.receiver_ctx);
            try grt.std.testing.expect(impl.emit_fn != null);

            reader.clearEventCallback();
            try grt.std.testing.expect(impl.receiver_ctx == null);
            try grt.std.testing.expect(impl.emit_fn == null);

            reader.stopScan();
            try grt.std.testing.expect(!impl.scanning);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.initSetsAndClearsEventCallback() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            t.run("io.TypeA", TypeA.TestRunner(grt));
            t.run("ndef", ndef.TestRunner(grt));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}

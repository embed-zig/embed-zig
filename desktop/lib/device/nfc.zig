const embed = @import("embed");
const glib = @import("glib");
const gstd = @import("gstd");

pub const Nfc = struct {
    mutex: gstd.runtime.sync.Mutex = .{},
    callback_ctx: ?*const anyopaque = null,
    callback_fn: ?embed.nfc.CallbackFn = null,
    scanning: bool = false,
    scan_config: embed.nfc.ScanConfig = .{},

    pub fn handle(self: *@This()) embed.nfc.Reader {
        return embed.nfc.Reader.init(self);
    }

    pub fn startScan(self: *@This(), config: embed.nfc.ScanConfig) embed.nfc.ScanError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.scanning = true;
        self.scan_config = config;
    }

    pub fn stopScan(self: *@This()) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.scanning = false;
    }

    pub fn setEventCallback(self: *@This(), ctx: *const anyopaque, emit_fn: embed.nfc.CallbackFn) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.callback_ctx = ctx;
        self.callback_fn = emit_fn;
    }

    pub fn clearEventCallback(self: *@This()) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.callback_ctx = null;
        self.callback_fn = null;
    }
};

pub fn TestRunner(comptime std: type) glib.testing.TestRunner {
    const testing_api = glib.testing;

    const Runner = struct {
        pub fn init(self: *@This(), allocator: std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            var nfc = Nfc{};
            const reader = nfc.handle();
            const callback_ctx: usize = 0x1234;
            const callback = struct {
                fn emitFn(_: *const anyopaque, _: embed.nfc.Update) void {}
            }.emitFn;

            reader.setEventCallback(@ptrFromInt(callback_ctx), callback);
            std.testing.expect(nfc.callback_fn != null) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            reader.startScan(.{ .interval_ms = 100, .read_payload = true }) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            std.testing.expect(nfc.scanning) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            std.testing.expect(nfc.scan_config.read_payload) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            reader.clearEventCallback();
            std.testing.expect(nfc.callback_fn == null) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            reader.stopScan();
            std.testing.expect(!nfc.scanning) catch |err| {
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

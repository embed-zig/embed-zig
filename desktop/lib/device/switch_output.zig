const embed = @import("embed");
const glib = @import("glib");
const gstd = @import("gstd");

pub const SwitchOutput = struct {
    pub const ChangeHook = *const fn (ctx: *anyopaque, output: *SwitchOutput) void;

    mutex: gstd.runtime.sync.Mutex = .{},
    enabled: bool = false,
    change_ctx: ?*anyopaque = null,
    change_hook: ?ChangeHook = null,

    pub fn handle(self: *@This()) embed.drivers.Switch {
        return embed.drivers.Switch.init(self);
    }

    pub fn setChangeHook(self: *@This(), ctx: *anyopaque, hook: ChangeHook) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.change_ctx = ctx;
        self.change_hook = hook;
    }

    pub fn clearChangeHook(self: *@This()) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.change_ctx = null;
        self.change_hook = null;
    }

    pub fn set(self: *@This(), enabled: bool) embed.drivers.Switch.Error!void {
        self.mutex.lock();
        const changed = self.enabled != enabled;
        self.enabled = enabled;
        const hook = self.change_hook;
        const ctx = self.change_ctx;
        self.mutex.unlock();

        if (changed) {
            if (hook) |callback| {
                const callback_ctx = ctx orelse return;
                callback(callback_ctx, self);
            }
        }
    }

    pub fn get(self: *@This()) embed.drivers.Switch.Error!bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.enabled;
    }
};

pub fn TestRunner(comptime std: type) glib.testing.TestRunner {
    const testing_api = glib.testing;

    const TestCase = struct {
        fn switchOutputTracksEnabledState() !void {
            var output = SwitchOutput{};
            const handle = output.handle();

            try std.testing.expect(!try handle.get());
            try handle.set(true);
            try std.testing.expect(try handle.get());
            try handle.set(false);
            try std.testing.expect(!try handle.get());
        }

        fn switchOutputRunsChangeHookOnStateChanges() !void {
            const HookState = struct {
                count: usize = 0,

                fn onChange(ctx: *anyopaque, output: *SwitchOutput) void {
                    _ = output;
                    const self: *@This() = @ptrCast(@alignCast(ctx));
                    self.count += 1;
                }
            };

            var state = HookState{};
            var output = SwitchOutput{};
            const handle = output.handle();
            output.setChangeHook(&state, HookState.onChange);

            try handle.set(false);
            try std.testing.expectEqual(@as(usize, 0), state.count);

            try handle.set(true);
            try std.testing.expectEqual(@as(usize, 1), state.count);

            try handle.set(true);
            try std.testing.expectEqual(@as(usize, 1), state.count);

            output.clearChangeHook();
            try handle.set(false);
            try std.testing.expectEqual(@as(usize, 1), state.count);
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

            TestCase.switchOutputTracksEnabledState() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.switchOutputRunsChangeHookOnStateChanges() catch |err| {
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

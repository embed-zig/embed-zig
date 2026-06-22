const glib = @import("glib");
const gstd = @import("gstd");

pub const GroupedButton = struct {
    pub const Handle = struct {
        button: *GroupedButton,

        pub fn pressedButtonId(self: @This()) !?u32 {
            return self.button.pressedButtonId();
        }
    };

    mutex: gstd.runtime.sync.Mutex = .{},
    pressed_button_id: ?u32 = null,

    pub fn handle(self: *@This()) Handle {
        return .{ .button = self };
    }

    pub fn pressedButtonId(self: *@This()) !?u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.pressed_button_id;
    }

    pub fn setPressedButtonId(self: *@This(), button_id: ?u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.pressed_button_id = button_id;
    }

    pub fn press(self: *@This(), button_id: u32) void {
        self.setPressedButtonId(button_id);
    }

    pub fn release(self: *@This()) void {
        self.setPressedButtonId(null);
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

            var button = GroupedButton{};
            const handle = button.handle();

            std.testing.expectEqual(@as(?u32, null), handle.pressedButtonId() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            }) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            button.press(4);
            std.testing.expectEqual(@as(?u32, 4), handle.pressedButtonId() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            }) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            button.release();
            std.testing.expectEqual(@as(?u32, null), handle.pressedButtonId() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            }) catch |err| {
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

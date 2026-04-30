const dep = @import("dep");
const embed_std = dep.embed_std;

pub const SingleButton = struct {
    pub const Handle = struct {
        button: *SingleButton,

        pub fn isPressed(self: @This()) !bool {
            return self.button.isPressed();
        }
    };

    mutex: embed_std.std.Thread.Mutex = .{},
    pressed: bool = false,

    pub fn handle(self: *@This()) Handle {
        return .{ .button = self };
    }

    pub fn isPressed(self: *@This()) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.pressed;
    }

    pub fn setPressed(self: *@This(), pressed: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.pressed = pressed;
    }

    pub fn press(self: *@This()) void {
        self.setPressed(true);
    }

    pub fn release(self: *@This()) void {
        self.setPressed(false);
    }
};

pub fn TestRunner(comptime lib: type) dep.testing.TestRunner {
    const testing_api = dep.testing;

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            var button = SingleButton{};
            const handle = button.handle();

            lib.testing.expect(!(handle.isPressed() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            })) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            button.press();
            lib.testing.expect(handle.isPressed() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            }) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            button.release();
            lib.testing.expect(!(handle.isPressed() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            })) catch |err| {
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

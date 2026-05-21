const embed = @import("embed");
const glib = @import("glib");
const gstd = @import("gstd");

const TouchApi = embed.drivers.Touch;

pub const Touch = struct {
    mutex: gstd.runtime.std.Thread.Mutex = .{},
    pressed: bool = false,
    point: TouchApi.Point = .{ .x = 0, .y = 0 },

    pub fn handle(self: *Touch) TouchApi {
        return TouchApi.init(self);
    }

    pub fn setDown(self: *Touch, x: u16, y: u16) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.pressed = true;
        self.point = .{ .id = 0, .x = x, .y = y, .pressure = 1 };
    }

    pub fn setMove(self: *Touch, x: u16, y: u16) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.pressed) return;
        self.point = .{ .id = 0, .x = x, .y = y, .pressure = 1 };
    }

    pub fn setUp(self: *Touch) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.pressed = false;
    }

    pub fn read(self: *Touch, points: []TouchApi.Point) !usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.pressed or points.len == 0) return 0;
        points[0] = self.point;
        return 1;
    }
};

pub fn TestRunner(comptime std: type) glib.testing.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: std.mem.Allocator) bool {
            _ = self;
            _ = allocator;
            var touch = Touch{};
            var points: [1]TouchApi.Point = undefined;
            touch.setDown(12, 34);
            const samples = touch.handle().read(points[0..]) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            std.testing.expectEqual(@as(usize, 1), samples.len) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            std.testing.expectEqual(@as(u16, 12), samples[0].x) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            touch.setUp();
            const released = touch.handle().read(points[0..]) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            std.testing.expectEqual(@as(usize, 0), released.len) catch |err| {
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
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}

const stdz = @import("stdz");
const testing_api = @import("testing");
const test_utils = @import("test_utils.zig");

pub fn make(comptime lib: type, comptime net: type) testing_api.TestRunner {
    const Runner = struct {
        spawn_config: stdz.Thread.SpawnConfig = .{ .stack_size = 320 * 1024 },

        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            const Body = struct {
                fn call(a: lib.mem.Allocator) !void {
                    const Net = net;

                    var ln = try Net.listen(a, .{ .address = test_utils.addr4(.{ 127, 0, 0, 1 }, 0) });
                    defer ln.deinit();

                    const port = try test_utils.listenerPort(ln, Net);
                    const dest = test_utils.addr4(.{ 127, 0, 0, 1 }, port);

                    var c1 = try Net.dial(a, .tcp, dest);
                    defer c1.deinit();
                    var a1 = try ln.accept();
                    defer a1.deinit();

                    var c2 = try Net.dial(a, .tcp, dest);
                    defer c2.deinit();
                    var a2 = try ln.accept();
                    defer a2.deinit();

                    _ = try c1.write("conn1");
                    _ = try c2.write("conn2");

                    var buf: [64]u8 = undefined;
                    const n1 = try a1.read(buf[0..]);
                    try lib.testing.expectEqualStrings("conn1", buf[0..n1]);

                    const n2 = try a2.read(buf[0..]);
                    try lib.testing.expectEqualStrings("conn2", buf[0..n2]);
                }
            };
            Body.call(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: stdz.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}

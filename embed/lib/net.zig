//! net — platform network-interface and route control contracts.

const glib = @import("glib");

pub const Manager = @import("net/Manager.zig");
pub const event = @import("net/event.zig");
pub const iface = @import("net/iface.zig");
pub const route = @import("net/route.zig");
pub const types = @import("net/types.zig");

pub const AddressFamily = types.AddressFamily;
pub const AddressInfo = types.AddressInfo;
pub const Error = types.Error;
pub const InterfaceId = types.InterfaceId;

pub const test_runner = struct {
    pub const unit = struct {
        pub fn make(comptime grt: type) glib.testing.TestRunner {
            return TestRunner(grt);
        }
    };
};

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn managerListsAndSetsDefaultByName() !void {
            const Impl = struct {
                last_default: ?route.Default = null,

                pub fn listInterfaces(_: *@This(), out: []iface.Info) Error![]iface.Info {
                    if (out.len < 2) return error.BufferTooSmall;
                    out[0] = try iface.Info.init(1, "wifi0");
                    out[0].flags.up = true;
                    try out[0].appendAddress(.{
                        .family = .ipv4,
                        .address = glib.net.netip.Addr.from4(.{ 192, 168, 1, 20 }),
                        .prefix_len = 24,
                    });

                    out[1] = try iface.Info.init(2, "ppp0");
                    out[1].flags.up = true;
                    return out[0..2];
                }

                pub fn getDefaultRoute(self: *@This(), family: AddressFamily) Error!?route.Default {
                    if (self.last_default) |default| {
                        if (default.family == family) return default;
                    }
                    return null;
                }

                pub fn setDefaultRoute(self: *@This(), default: route.Default) Error!void {
                    self.last_default = default;
                }
            };

            var impl = Impl{};
            const manager = Manager.init(&impl);
            var list_buf: [4]iface.Info = undefined;
            const list = try manager.listInterfaces(&list_buf);
            try grt.std.testing.expectEqual(@as(usize, 2), list.len);
            try grt.std.testing.expectEqualStrings("wifi0", list[0].name());
            try grt.std.testing.expectEqual(@as(usize, 1), list[0].addresses().len);

            try manager.setDefaultRouteByName(.ipv4, "ppp0", &list_buf);
            const default = (try manager.getDefaultRoute(.ipv4)).?;
            try grt.std.testing.expectEqual(@as(InterfaceId, 2), default.interface_id);
        }

        fn interfaceNameCapacityIsChecked() !void {
            const long_name = "012345678901234567890123456789012";
            try grt.std.testing.expectError(error.BufferTooSmall, iface.Info.init(1, long_name));
        }

        fn defaultEventCallbackIsUnsupported() !void {
            const Impl = struct {
                pub fn listInterfaces(_: *@This(), out: []iface.Info) Error![]iface.Info {
                    return out[0..0];
                }

                pub fn getDefaultRoute(_: *@This(), _: AddressFamily) Error!?route.Default {
                    return null;
                }

                pub fn setDefaultRoute(_: *@This(), _: route.Default) Error!void {}
            };

            var impl = Impl{};
            const manager = Manager.init(&impl);
            const callback = struct {
                fn emit(_: *const anyopaque, _: event.Event) void {}
            }.emit;
            try grt.std.testing.expectError(error.Unsupported, manager.setEventCallback(@ptrFromInt(@as(usize, 1)), callback));
            manager.clearEventCallback();
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

            TestCase.managerListsAndSetsDefaultByName() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.interfaceNameCapacityIsChecked() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.defaultEventCallbackIsUnsupported() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
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

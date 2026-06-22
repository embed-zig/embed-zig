const interfaces_mod = @import("interfaces.zig");
const netip = @import("netip.zig");
const types = @import("types.zig");

pub const InterfaceId = types.InterfaceId;
pub const AddressFamily = types.AddressFamily;
pub const Error = types.Error;

pub const Default = struct {
    family: AddressFamily,
    interface_id: InterfaceId,
    gateway: ?netip.Addr = null,
    metric: u32 = 0,
};

const RootDefault = Default;

pub fn make(comptime std: type, comptime NetApi: type, comptime impl: type) type {
    _ = std;
    return struct {
        const BoundNetApi = NetApi;

        pub const InterfaceId = types.InterfaceId;
        pub const AddressFamily = types.AddressFamily;
        pub const Error = types.Error;
        pub const Default = RootDefault;

        pub fn getDefault(family: types.AddressFamily) types.Error!?RootDefault {
            if (comptime hasImpl("getDefault")) {
                return impl.routes.getDefault(family);
            }
            return error.Unsupported;
        }

        pub fn setDefault(route: RootDefault) types.Error!void {
            if (comptime hasImpl("setDefault")) {
                return impl.routes.setDefault(route);
            }
            return error.Unsupported;
        }

        pub fn setDefaultByName(
            family: types.AddressFamily,
            name: []const u8,
            scratch: []interfaces_mod.Info,
        ) types.Error!void {
            const items = try BoundNetApi.interfaces.list(scratch);
            const item = interfaces_mod.findByName(items, name) orelse return error.InvalidInterface;
            return setDefault(.{
                .family = family,
                .interface_id = item.id,
            });
        }

        fn hasImpl(comptime name: []const u8) bool {
            return @hasDecl(impl, "routes") and @hasDecl(impl.routes, name);
        }
    };
}

pub fn TestRunner(comptime std: type) @import("testing").TestRunner {
    const TestCase = struct {
        const FakeImpl = struct {
            pub const interfaces = struct {
                pub fn list(out: []interfaces_mod.Info) Error![]interfaces_mod.Info {
                    if (out.len < 2) return error.BufferTooSmall;
                    out[0] = interfaces_mod.Info.init(1, "lo0");
                    out[1] = interfaces_mod.Info.init(2, "wlan0");
                    return out[0..2];
                }
            };

            pub const routes = struct {
                var default_route: ?Default = null;

                pub fn getDefault(_: AddressFamily) Error!?Default {
                    return default_route;
                }

                pub fn setDefault(route: Default) Error!void {
                    default_route = route;
                }
            };
        };

        const FakeNet = struct {
            pub const interfaces = interfaces_mod.make(std, @This(), FakeImpl);
        };

        fn setDefaultByNameUsesInterfaceList() !void {
            const Routes = make(std, FakeNet, FakeImpl);
            FakeImpl.routes.default_route = null;

            var scratch: [2]interfaces_mod.Info = undefined;
            try Routes.setDefaultByName(.ipv4, "wlan0", &scratch);

            const default = (try Routes.getDefault(.ipv4)).?;
            try std.testing.expectEqual(@as(InterfaceId, 2), default.interface_id);
            try std.testing.expectEqual(AddressFamily.ipv4, default.family);
        }

        fn unsupportedBackendKeepsApiVisible() !void {
            const UnsupportedNet = struct {
                pub const interfaces = interfaces_mod.make(std, @This(), struct {});
            };
            const Routes = make(std, UnsupportedNet, struct {});
            try std.testing.expectError(error.Unsupported, Routes.getDefault(.ipv4));
            try std.testing.expectError(error.Unsupported, Routes.setDefault(.{
                .family = .ipv4,
                .interface_id = 1,
            }));
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *@import("testing").T, allocator: std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.setDefaultByNameUsesInterfaceList() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.unsupportedBackendKeepsApiVisible() catch |err| {
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
    return @import("testing").TestRunner.make(Runner).new(&Holder.runner);
}

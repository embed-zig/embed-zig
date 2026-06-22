const types = @import("types.zig");

pub const InterfaceId = types.InterfaceId;
pub const AddressFamily = types.AddressFamily;
pub const AddressInfo = types.AddressInfo;
pub const Error = types.Error;

pub const max_name_len: usize = 32;
pub const max_addresses_per_interface: usize = 4;

pub const Flags = struct {
    up: bool = false,
    running: bool = false,
    loopback: bool = false,
    default: bool = false,
};

pub const Info = struct {
    id: InterfaceId = 0,
    name_buf: [max_name_len]u8 = [_]u8{0} ** max_name_len,
    name_len: u8 = 0,
    flags: Flags = .{},
    addresses_buf: [max_addresses_per_interface]AddressInfo = undefined,
    address_count: u8 = 0,

    pub fn init(id: InterfaceId, value: []const u8) Info {
        var info = Info{ .id = id };
        const len = @min(value.len, info.name_buf.len);
        @memcpy(info.name_buf[0..len], value[0..len]);
        info.name_len = @intCast(len);
        return info;
    }

    pub fn name(self: *const Info) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn setName(self: *Info, value: []const u8) Error!void {
        if (value.len > self.name_buf.len) return error.BufferTooSmall;
        @memset(&self.name_buf, 0);
        @memcpy(self.name_buf[0..value.len], value);
        self.name_len = @intCast(value.len);
    }

    pub fn addresses(self: *const Info) []const AddressInfo {
        return self.addresses_buf[0..self.address_count];
    }

    pub fn appendAddress(self: *Info, address: AddressInfo) Error!void {
        if (self.address_count >= self.addresses_buf.len) return error.BufferTooSmall;
        self.addresses_buf[self.address_count] = address;
        self.address_count += 1;
    }
};

pub const AddressChange = struct {
    interface_id: InterfaceId,
    address: AddressInfo,
};

pub const Event = union(enum) {
    up: InterfaceId,
    down: InterfaceId,
    address_added: AddressChange,
    address_removed: AddressChange,
    default_route_changed: AddressFamily,
};

pub const EventHook = struct {
    ctx: *anyopaque,
    callback: *const fn (ctx: *anyopaque, event: Event) void,
};

const RootFlags = Flags;
const RootInfo = Info;
const RootAddressChange = AddressChange;
const RootEvent = Event;
const RootEventHook = EventHook;

pub fn findByName(items: []const Info, needle: []const u8) ?Info {
    for (items) |item| {
        if (eqlBytes(item.name(), needle)) return item;
    }
    return null;
}

pub fn findById(items: []const Info, id: InterfaceId) ?Info {
    for (items) |item| {
        if (item.id == id) return item;
    }
    return null;
}

pub fn make(comptime std: type, comptime NetApi: type, comptime impl: type) type {
    _ = std;
    _ = NetApi;
    return struct {
        pub const InterfaceId = types.InterfaceId;
        pub const AddressFamily = types.AddressFamily;
        pub const AddressInfo = types.AddressInfo;
        pub const Error = types.Error;
        pub const Flags = RootFlags;
        pub const Info = RootInfo;
        pub const AddressChange = RootAddressChange;
        pub const Event = RootEvent;
        pub const EventHook = RootEventHook;

        pub fn list(out: []RootInfo) types.Error![]RootInfo {
            if (comptime hasImpl("list")) {
                return impl.interfaces.list(out);
            }
            return error.Unsupported;
        }

        pub fn addEventHook(hook: RootEventHook) types.Error!void {
            if (comptime hasImpl("addEventHook")) {
                return impl.interfaces.addEventHook(hook);
            }
            return error.Unsupported;
        }

        pub fn removeEventHook(hook: RootEventHook) types.Error!void {
            if (comptime hasImpl("removeEventHook")) {
                return impl.interfaces.removeEventHook(hook);
            }
            return error.Unsupported;
        }

        pub fn findByName(items: []const RootInfo, needle: []const u8) ?RootInfo {
            return findByNameRoot(items, needle);
        }

        pub fn findById(items: []const RootInfo, id: types.InterfaceId) ?RootInfo {
            return findByIdRoot(items, id);
        }

        fn hasImpl(comptime name: []const u8) bool {
            return @hasDecl(impl, "interfaces") and @hasDecl(impl.interfaces, name);
        }
    };
}

fn eqlBytes(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (left != right) return false;
    }
    return true;
}

fn findByNameRoot(items: []const RootInfo, needle: []const u8) ?RootInfo {
    return findByName(items, needle);
}

fn findByIdRoot(items: []const RootInfo, id: types.InterfaceId) ?RootInfo {
    return findById(items, id);
}

pub fn TestRunner(comptime std: type) @import("testing").TestRunner {
    const TestCase = struct {
        fn infoNameAndAddressBufferBounds() !void {
            var info = Info.init(7, "wlan0");
            try std.testing.expectEqual(@as(InterfaceId, 7), info.id);
            try std.testing.expectEqualStrings("wlan0", info.name());

            try info.appendAddress(.{
                .family = .ipv4,
                .address = @import("netip.zig").Addr.from4(.{ 192, 168, 1, 10 }),
                .prefix_len = 24,
            });
            try std.testing.expectEqual(@as(usize, 1), info.addresses().len);
            try std.testing.expectEqual(@as(u8, 24), info.addresses()[0].prefix_len);

            const long_name: [max_name_len + 1]u8 = [_]u8{'a'} ** (max_name_len + 1);
            try std.testing.expectError(error.BufferTooSmall, info.setName(&long_name));

            const truncated = Info.init(8, &long_name);
            try std.testing.expectEqual(@as(usize, max_name_len), truncated.name().len);
        }

        fn unsupportedBackendKeepsApiVisible() !void {
            const Api = make(std, struct {}, struct {});
            var out: [1]Api.Info = undefined;
            try std.testing.expectError(error.Unsupported, Api.list(&out));
            try std.testing.expectError(error.Unsupported, Api.addEventHook(.{
                .ctx = undefined,
                .callback = struct {
                    fn emit(_: *anyopaque, _: Api.Event) void {}
                }.emit,
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

            TestCase.infoNameAndAddressBufferBounds() catch |err| {
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

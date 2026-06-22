const event = @import("event.zig");
const iface = @import("iface.zig");
const route = @import("route.zig");
const types = @import("types.zig");

const Manager = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    listInterfaces: *const fn (ptr: *anyopaque, out: []iface.Info) types.Error![]iface.Info,
    getDefaultRoute: *const fn (ptr: *anyopaque, family: types.AddressFamily) types.Error!?route.Default,
    setDefaultRoute: *const fn (ptr: *anyopaque, default: route.Default) types.Error!void,
    setEventCallback: *const fn (ptr: *anyopaque, ctx: *const anyopaque, emit_fn: event.CallbackFn) types.Error!void,
    clearEventCallback: *const fn (ptr: *anyopaque) void,
};

pub fn init(pointer: anytype) Manager {
    const Ptr = @TypeOf(pointer);
    const info = @typeInfo(Ptr);
    if (info != .pointer or info.pointer.size != .one)
        @compileError("net.Manager.init expects a single-item pointer");

    const Impl = info.pointer.child;

    const gen = struct {
        fn listInterfacesFn(ptr: *anyopaque, out: []iface.Info) types.Error![]iface.Info {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.listInterfaces(out);
        }

        fn getDefaultRouteFn(ptr: *anyopaque, family: types.AddressFamily) types.Error!?route.Default {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.getDefaultRoute(family);
        }

        fn setDefaultRouteFn(ptr: *anyopaque, default: route.Default) types.Error!void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.setDefaultRoute(default);
        }

        fn setEventCallbackFn(ptr: *anyopaque, ctx: *const anyopaque, emit_fn: event.CallbackFn) types.Error!void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            if (@hasDecl(Impl, "setEventCallback")) {
                return self.setEventCallback(ctx, emit_fn);
            }
            return error.Unsupported;
        }

        fn clearEventCallbackFn(ptr: *anyopaque) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            if (@hasDecl(Impl, "clearEventCallback")) {
                self.clearEventCallback();
            }
        }

        const vtable = VTable{
            .listInterfaces = listInterfacesFn,
            .getDefaultRoute = getDefaultRouteFn,
            .setDefaultRoute = setDefaultRouteFn,
            .setEventCallback = setEventCallbackFn,
            .clearEventCallback = clearEventCallbackFn,
        };
    };

    return .{
        .ptr = pointer,
        .vtable = &gen.vtable,
    };
}

pub fn listInterfaces(self: Manager, out: []iface.Info) types.Error![]iface.Info {
    return self.vtable.listInterfaces(self.ptr, out);
}

pub fn getDefaultRoute(self: Manager, family: types.AddressFamily) types.Error!?route.Default {
    return self.vtable.getDefaultRoute(self.ptr, family);
}

pub fn setDefaultRoute(self: Manager, default: route.Default) types.Error!void {
    return self.vtable.setDefaultRoute(self.ptr, default);
}

pub fn setDefaultRouteByName(
    self: Manager,
    family: types.AddressFamily,
    name: []const u8,
    scratch: []iface.Info,
) types.Error!void {
    const items = try self.listInterfaces(scratch);
    const item = iface.findByName(items, name) orelse return error.InvalidInterface;
    return self.setDefaultRoute(.{
        .family = family,
        .interface_id = item.id,
    });
}

pub fn setEventCallback(self: Manager, ctx: *const anyopaque, emit_fn: event.CallbackFn) types.Error!void {
    return self.vtable.setEventCallback(self.ptr, ctx, emit_fn);
}

pub fn clearEventCallback(self: Manager) void {
    self.vtable.clearEventCallback(self.ptr);
}

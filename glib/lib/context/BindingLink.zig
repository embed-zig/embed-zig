//! BindingLink — type-erased cancel side effect stored on a context node.

const BindingLink = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    fireFn: *const fn (ptr: *anyopaque, cause: anyerror) void,
    deactivateFn: *const fn (ptr: *anyopaque) void,
};

pub fn fdLink(comptime std: type, fd: *std.posix.socket_t) BindingLink {
    const posix = std.posix;

    const gen = struct {
        fn fireFn(ptr: *anyopaque, cause: anyerror) void {
            const same_cause = cause == error.BrokenPipe;
            _ = same_cause;
            const fd_ptr: *posix.socket_t = @ptrCast(@alignCast(ptr));
            const wake_byte = [_]u8{0};
            _ = posix.send(fd_ptr.*, wake_byte[0..], 0) catch {};
        }

        fn deactivateFn(ptr: *anyopaque) void {
            _ = ptr;
        }

        const vtable = VTable{
            .fireFn = fireFn,
            .deactivateFn = deactivateFn,
        };
    };

    return .{
        .ptr = @ptrCast(fd),
        .vtable = &gen.vtable,
    };
}

pub fn fire(self: BindingLink, cause: anyerror) void {
    self.vtable.fireFn(self.ptr, cause);
}

pub fn deactivate(self: BindingLink) void {
    self.vtable.deactivateFn(self.ptr);
}

//! Small shared helpers for TCP integration cases (no `For(lib)` facade).
const net_mod = @import("../../../../net.zig");

pub fn allocatorAlignment(comptime any_lib: type) type {
    const alloc_ptr_type = @TypeOf(any_lib.testing.allocator.vtable.alloc);
    const alloc_fn_type = @typeInfo(alloc_ptr_type).pointer.child;
    return @typeInfo(alloc_fn_type).@"fn".params[2].type.?;
}

pub fn OneShotAllocatorType(comptime any_lib: type) type {
    const Allocator = any_lib.mem.Allocator;
    const Alignment = allocatorAlignment(any_lib);

    return struct {
        backing: Allocator,
        allocations_left: usize = 1,

        const Self = @This();

        pub fn allocator(self: *Self) Allocator {
            return .{
                .ptr = self,
                .vtable = &vtable,
            };
        }

        fn allocate(ptr: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ptr));
            if (self.allocations_left == 0) return null;
            self.allocations_left -= 1;
            return self.backing.rawAlloc(len, alignment, ret_addr);
        }

        fn resize(ptr: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.backing.rawResize(memory, alignment, new_len, ret_addr);
        }

        fn remap(ptr: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
        }

        fn free(ptr: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.backing.rawFree(memory, alignment, ret_addr);
        }

        const vtable: Allocator.VTable = .{
            .alloc = allocate,
            .resize = resize,
            .remap = remap,
            .free = free,
        };
    };
}

pub fn fillPattern(buf: []u8, seed: u8) void {
    for (buf, 0..) |*byte, i| {
        byte.* = @truncate((i * 131 + seed) % 251);
    }
}

pub fn skipIfConnectDidNotPend(err: anyerror) anyerror!void {
    switch (err) {
        error.AccessDenied,
        error.PermissionDenied,
        error.AddressInUse,
        error.AddressNotAvailable,
        error.AddressFamilyNotSupported,
        error.ConnectionRefused,
        error.NetworkUnreachable,
        error.ConnectionTimedOut,
        error.ConnectionResetByPeer,
        error.FileNotFound,
        error.SystemResources,
        error.ConnectFailed,
        => return error.SkipZigTest,
        else => return err,
    }
}

pub fn listenerPort(ln: net_mod.Listener, comptime net: type) !u16 {
    const typed = try ln.as(net.TcpListener);
    return typed.port();
}

pub fn addr4(addr: [4]u8, port: u16) net_mod.netip.AddrPort {
    return net_mod.netip.AddrPort.from4(addr, port);
}

pub fn addr6(text: []const u8, port: u16) !net_mod.netip.AddrPort {
    return net_mod.netip.AddrPort.init(try net_mod.netip.Addr.parse(text), port);
}

pub fn StartGate(comptime lib: type) type {
    const Thread = lib.Thread;
    return struct {
        mutex: Thread.Mutex = .{},
        cond: Thread.Condition = .{},
        ready: usize = 0,
        target: usize,

        pub fn init(target: usize) @This() {
            return .{ .target = target };
        }

        pub fn wait(self: *@This()) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.ready += 1;
            if (self.ready == self.target) {
                self.cond.broadcast();
                return;
            }
            while (self.ready < self.target) self.cond.wait(&self.mutex);
        }
    };
}

pub fn ReadyCounter(comptime lib: type) type {
    const Thread = lib.Thread;
    return struct {
        mutex: Thread.Mutex = .{},
        cond: Thread.Condition = .{},
        ready: usize = 0,
        target: usize,

        pub fn init(target: usize) @This() {
            return .{ .target = target };
        }

        pub fn markReady(self: *@This()) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.ready += 1;
            self.cond.broadcast();
        }

        pub fn waitUntilReady(self: *@This()) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (self.ready < self.target) self.cond.wait(&self.mutex);
        }
    };
}

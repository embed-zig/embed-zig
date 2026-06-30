//! KCP bindings backed by the local C KCP implementation.

const glib = @import("glib");

pub const c = @cImport({
    @cInclude("ikcp.h");
});

pub const Kcp = c.ikcpcb;
pub const Allocator = c.IKCPALLOC;
pub const OVERHEAD: usize = 24;

pub fn create(conv: u32, user: ?*anyopaque) ?*Kcp {
    return c.ikcp_create(@as(c.IUINT32, @intCast(conv)), user);
}

pub fn createWithAllocator(conv: u32, user: ?*anyopaque, alloc: Allocator) ?*Kcp {
    return c.ikcp_create_with_allocator(@as(c.IUINT32, @intCast(conv)), user, alloc);
}

pub fn release(inst: *Kcp) void {
    c.ikcp_release(inst);
}

pub fn setOutput(
    inst: *Kcp,
    output: *const fn ([*c]const u8, c_int, [*c]Kcp, ?*anyopaque) callconv(.c) c_int,
) void {
    c.ikcp_setoutput(inst, output);
}

pub fn recv(inst: *Kcp, buffer: [*]u8, len: c_int) c_int {
    return c.ikcp_recv(inst, @ptrCast(buffer), len);
}

pub fn peeksize(inst: *const Kcp) c_int {
    return c.ikcp_peeksize(inst);
}

pub fn send(inst: *Kcp, buffer: [*]const u8, len: c_int) c_int {
    return c.ikcp_send(inst, @ptrCast(buffer), len);
}

pub fn update(inst: *Kcp, current: u32) void {
    c.ikcp_update(inst, @as(c.IUINT32, @intCast(current)));
}

pub fn check(inst: *const Kcp, current: u32) u32 {
    return @intCast(c.ikcp_check(inst, @as(c.IUINT32, @intCast(current))));
}

pub fn input(inst: *Kcp, data: [*]const u8, size: usize) c_int {
    return c.ikcp_input(inst, @ptrCast(data), @as(c_long, @intCast(size)));
}

pub fn flush(inst: *Kcp) void {
    c.ikcp_flush(inst);
}

pub fn setMtu(inst: *Kcp, mtu: c_int) c_int {
    return c.ikcp_setmtu(inst, mtu);
}

pub fn wndsize(inst: *Kcp, send_window: c_int, recv_window: c_int) c_int {
    return c.ikcp_wndsize(inst, send_window, recv_window);
}

pub fn waitsnd(inst: *const Kcp) c_int {
    return c.ikcp_waitsnd(inst);
}

pub fn nodelay(inst: *Kcp, nodelay_: c_int, interval: c_int, resend: c_int, no_congestion_control: c_int) c_int {
    return c.ikcp_nodelay(inst, nodelay_, interval, resend, no_congestion_control);
}

pub const allocator = c.ikcp_allocator;

pub const test_runner = struct {
    pub const unit = struct {
        pub fn make(comptime grt: type) glib.testing.TestRunner {
            const TestCase = struct {
                const OutputState = struct {
                    packets: usize = 0,
                    bytes: usize = 0,
                };

                fn output(buf: [*c]const u8, len: c_int, _: [*c]Kcp, user: ?*anyopaque) callconv(.c) c_int {
                    _ = buf;
                    const state: *OutputState = @ptrCast(@alignCast(user.?));
                    state.packets += 1;
                    state.bytes += @intCast(len);
                    return 0;
                }

                fn createConfigureAndFlush() !void {
                    var state = OutputState{};
                    const inst = create(42, &state) orelse return error.TestUnexpectedResult;
                    defer release(inst);

                    setOutput(inst, output);
                    try grt.std.testing.expectEqual(@as(c_int, 0), setMtu(inst, 1200));
                    try grt.std.testing.expectEqual(@as(c_int, 0), wndsize(inst, 32, 32));
                    try grt.std.testing.expectEqual(@as(c_int, 0), nodelay(inst, 1, 10, 2, 1));

                    const payload = [_]u8{ 'h', 'e', 'l', 'l', 'o' };
                    try grt.std.testing.expectEqual(@as(c_int, @intCast(payload.len)), send(inst, payload[0..].ptr, payload.len));
                    update(inst, 0);
                    flush(inst);

                    try grt.std.testing.expect(state.packets > 0);
                    try grt.std.testing.expect(state.bytes > OVERHEAD);
                    try grt.std.testing.expect(waitsnd(inst) >= 0);
                    _ = check(inst, 0);
                }
            };

            const Runner = struct {
                pub fn init(self: *@This(), allocator_: glib.std.mem.Allocator) !void {
                    _ = self;
                    _ = allocator_;
                }

                pub fn run(self: *@This(), t: *glib.testing.T, allocator_: glib.std.mem.Allocator) bool {
                    _ = self;
                    _ = allocator_;

                    TestCase.createConfigureAndFlush() catch |err| {
                        t.logFatal(@errorName(err));
                        return false;
                    };
                    return true;
                }

                pub fn deinit(self: *@This(), allocator_: glib.std.mem.Allocator) void {
                    _ = self;
                    _ = allocator_;
                }
            };

            const Holder = struct {
                var runner: Runner = .{};
            };
            return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
        }
    };
};

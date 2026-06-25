//! KCP bindings backed by the local C KCP implementation.

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

pub const BytesRing = @import("kcp/BytesRing.zig");
pub const PacketRing = @import("kcp/PacketRing.zig");
pub const SegmentPool = @import("kcp/SegmentPool.zig");
pub const Session = @import("kcp/Session.zig");
pub const PerfProtocol = @import("kcp/PerfProtocol.zig");
pub const PerfEndpoint = @import("kcp/PerfEndpoint.zig");
pub const PerfServer = @import("kcp/PerfServer.zig");
pub const PerfClient = @import("kcp/PerfClient.zig");

pub fn NetperfServer(comptime grt: type) type {
    return PerfServer.make(grt);
}

pub fn NetperfClient(comptime grt: type) type {
    return PerfClient.make(grt);
}

pub const test_runner = struct {
    pub const unit = @import("kcp/test_runner/unit.zig");
    pub const integration = @import("kcp/test_runner/integration.zig");
    pub const benchmark = @import("kcp/test_runner/benchmark.zig");
};

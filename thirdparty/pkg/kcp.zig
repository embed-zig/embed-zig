//! KCP bindings backed by the local C KCP implementation.

pub const c = @cImport({
    @cInclude("ikcp.h");
});

pub const Kcp = c.ikcpcb;
pub const Allocator = c.IKCPALLOC;
pub const OVERHEAD: usize = 24;

pub const create = c.ikcp_create;
pub const createWithAllocator = c.ikcp_create_with_allocator;
pub const release = c.ikcp_release;
pub const setOutput = c.ikcp_setoutput;
pub const recv = c.ikcp_recv;
pub const peeksize = c.ikcp_peeksize;
pub const send = c.ikcp_send;
pub const update = c.ikcp_update;
pub const check = c.ikcp_check;
pub const input = c.ikcp_input;
pub const flush = c.ikcp_flush;
pub const setMtu = c.ikcp_setmtu;
pub const wndsize = c.ikcp_wndsize;
pub const waitsnd = c.ikcp_waitsnd;
pub const nodelay = c.ikcp_nodelay;
pub const allocator = c.ikcp_allocator;

pub const SegmentPool = @import("kcp/SegmentPool.zig");
pub const PerfProtocol = @import("kcp/PerfProtocol.zig");

pub const test_runner = struct {
    pub const unit = @import("kcp/test_runner/unit.zig");
    pub const integration = @import("kcp/test_runner/integration.zig");
};

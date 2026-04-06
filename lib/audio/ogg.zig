//! audio/ogg - pure Zig Ogg primitives and state machines.

pub const types = @import("ogg/types.zig");
pub const crc = @import("ogg/crc.zig");
pub const PackBuffer = @import("ogg/PackBuffer.zig");
pub const Page = @import("ogg/Page.zig");
pub const Packet = @import("ogg/Packet.zig");
pub const Stream = @import("ogg/Stream.zig");
pub const Sync = @import("ogg/Sync.zig");

pub const PacketResult = Stream.PacketResult;
pub const PageSeekResult = Sync.PageSeekResult;
pub const PageOutResult = Sync.PageOutResult;

pub const test_runner = struct {
    pub const unit = @import("test_runner/unit/ogg.zig");
};

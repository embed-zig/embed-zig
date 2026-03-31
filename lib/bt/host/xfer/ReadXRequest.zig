//! xfer.ReadXRequest — logical server-side read_x request.

const Chunk = @import("Chunk.zig");

conn_handle: u16,
service_uuid: u16,
char_uuid: u16,
topic: ?Chunk.Topic = null,
metadata: []const u8 = &.{},

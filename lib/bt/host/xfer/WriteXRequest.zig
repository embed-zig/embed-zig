//! xfer.WriteXRequest — logical server-side write_x request.

conn_handle: u16,
service_uuid: u16,
char_uuid: u16,
data: []const u8,

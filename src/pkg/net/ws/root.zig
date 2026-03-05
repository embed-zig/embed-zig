//! WebSocket Client — RFC 6455
//!
//! Cross-platform WebSocket client generic over `net.Conn`.
//! Works with plain TCP (via SocketConn), TLS streams, or any byte stream.

pub const frame = @import("frame.zig");
pub const handshake = @import("handshake.zig");
pub const client = @import("client.zig");
pub const sha1 = @import("sha1.zig");
pub const base64 = @import("base64.zig");

pub const Frame = frame.Frame;
pub const FrameHeader = frame.FrameHeader;
pub const Opcode = frame.Opcode;
pub const Message = client.Message;
pub const MessageType = client.MessageType;

pub fn Client(comptime Conn: type) type {
    return client.Client(Conn);
}

test {
    _ = frame;
    _ = handshake;
    _ = client;
    _ = sha1;
    _ = base64;
    _ = @import("e2e_test.zig");
}

//! AT-style command/response helpers over byte streams (`lib/at`).
//!
//! Public surface: [`Transport`](at/Transport.zig) (wire your UART/USB `read`/`write`) and
//! [`Peer`](at/Peer.zig) (line framing, `exchange`, automatic RX flush + reader reset per command).
//! Canned **DCE** smoke loops for host tests belong in the board/firmware app (e.g. ESP `at_peer`), not here.

pub const Transport = @import("at/Transport.zig");
pub const Peer = @import("at/Peer.zig");
pub const test_runner = struct {
    pub const unit = @import("at/test_runner/unit.zig");
    pub const integration = @import("at/test_runner/integration.zig");
};

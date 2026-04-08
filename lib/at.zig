//! AT-style command/response helpers over byte streams (`lib/at`).

pub const Transport = @import("at/Transport.zig");
pub const LineReader = @import("at/LineReader.zig").LineReader;
pub const ReadLineError = @import("at/LineReader.zig").ReadLineError;
pub const Session = @import("at/Session.zig");

test "at/unit_tests/root_imports" {
    _ = Transport;
    _ = LineReader(64);
    const Lib = struct {
        pub const mem = @import("embed").mem;
        pub const time = struct {
            pub fn milliTimestamp() i64 {
                return 0;
            }
        };
    };
    _ = Session.make(Lib, 64);
}

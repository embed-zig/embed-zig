//! textproto — shared text-protocol helpers for `lib/net`.

pub const Reader = @import("textproto/Reader.zig").Reader;
pub const Writer = @import("textproto/Writer.zig").Writer;

pub fn make(comptime lib: type) type {
    _ = lib;

    return struct {
        pub const Reader = @import("textproto/Reader.zig").Reader;
        pub const Writer = @import("textproto/Writer.zig").Writer;
    };
}

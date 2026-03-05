pub const url = @import("url.zig");

pub const Url = url.Url;
pub const QueryIterator = url.QueryIterator;
pub const ParseError = url.ParseError;
pub const parse = url.parse;

test {
    _ = url;
}

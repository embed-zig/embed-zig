//! Header — HTTP header entry.
//!
//! This is a minimal allocation-free representation used by Request,
//! Response, and Transport. Higher-level helpers can be layered on top later.

const std = @import("std");

const Header = @This();

name: []const u8,
value: []const u8,

pub const accept = "Accept";
pub const accept_encoding = "Accept-Encoding";
pub const authorization = "Authorization";
pub const cache_control = "Cache-Control";
pub const connection = "Connection";
pub const content_encoding = "Content-Encoding";
pub const content_length = "Content-Length";
pub const content_type = "Content-Type";
pub const cookie = "Cookie";
pub const expect = "Expect";
pub const host = "Host";
pub const location = "Location";
pub const set_cookie = "Set-Cookie";
pub const trailer = "Trailer";
pub const transfer_encoding = "Transfer-Encoding";
pub const user_agent = "User-Agent";

pub fn init(name: []const u8, value: []const u8) Header {
    return .{
        .name = name,
        .value = value,
    };
}

/// HTTP header field names are case-insensitive.
pub fn is(self: Header, expected_name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(self.name, expected_name);
}

test "net/unit_tests/http/Header/stores_name_value_slices" {
    const hdr = Header.init(Header.content_type, "text/plain");

    try std.testing.expectEqualStrings("Content-Type", hdr.name);
    try std.testing.expectEqualStrings("text/plain", hdr.value);
}

test "net/unit_tests/http/Header/names_expose_common_constants" {
    try std.testing.expectEqualStrings("Host", Header.host);
    try std.testing.expectEqualStrings("User-Agent", Header.user_agent);
    try std.testing.expectEqualStrings("Content-Length", Header.content_length);
}

test "net/unit_tests/http/Header/is_compares_names_case_insensitively" {
    const hdr = Header.init("content-type", "text/plain");

    try std.testing.expect(hdr.is(Header.content_type));
    try std.testing.expect(!hdr.is(Header.authorization));
}

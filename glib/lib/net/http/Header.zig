//! Header — HTTP header entry.
//!
//! This is a minimal allocation-free representation used by Request,
//! Response, and Transport. Higher-level helpers can be layered on top later.

const host_std = @import("std");
const testing_api = @import("testing");

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
pub const proxy_authorization = "Proxy-Authorization";
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
    return host_std.ascii.eqlIgnoreCase(self.name, expected_name);
}

pub fn TestRunner(comptime std: type) testing_api.TestRunner {
    return testing_api.TestRunner.fromFn(std, 3 * 1024 * 1024, struct {
        fn run(_: *testing_api.T, _: std.mem.Allocator) !void {
            const testing = std.testing;

            const hdr = Header.init(Header.content_type, "text/plain");
            try testing.expectEqualStrings("Content-Type", hdr.name);
            try testing.expectEqualStrings("text/plain", hdr.value);

            try testing.expectEqualStrings("Host", Header.host);
            try testing.expectEqualStrings("User-Agent", Header.user_agent);
            try testing.expectEqualStrings("Content-Length", Header.content_length);
            try testing.expectEqualStrings("Proxy-Authorization", Header.proxy_authorization);

            const lower = Header.init("content-type", "text/plain");
            try testing.expect(lower.is(Header.content_type));
            try testing.expect(!lower.is(Header.authorization));
        }
    }.run);
}

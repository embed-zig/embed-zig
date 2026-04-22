//! mime — MIME media type and content helpers.
//!
//! Mirrors Go's top-level `mime` package rather than living under `net/`.
//! The package will grow parsing/formatting helpers and common MIME-related
//! utilities as the HTTP stack expands.

pub const MediaType = @import("mime/MediaType.zig");
pub const test_runner = struct {
    pub const unit = @import("mime/test_runner/unit.zig");
};

pub fn parse(input: []const u8, params_buf: []MediaType.Parameter) MediaType.ParseError!MediaType {
    return MediaType.parse(input, params_buf);
}

pub fn format(media_type: MediaType, writer: anytype) !void {
    return media_type.format(writer);
}

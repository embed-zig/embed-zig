//! Base64 utilities — re-exports from std.base64.

const re_export = struct {
    const std = @import("std");

    pub const Base64Decoder = std.base64.Base64Decoder;
    pub const Base64Encoder = std.base64.Base64Encoder;
    pub const Codecs = std.base64.Codecs;
    pub const Error = std.base64.Error;
    pub const standard = std.base64.standard;
    pub const standard_no_pad = std.base64.standard_no_pad;
    pub const url_safe = std.base64.url_safe;
    pub const url_safe_no_pad = std.base64.url_safe_no_pad;
};

pub const Base64Decoder = re_export.Base64Decoder;
pub const Base64Encoder = re_export.Base64Encoder;
pub const Codecs = re_export.Codecs;
pub const Error = re_export.Error;
pub const standard = re_export.standard;
pub const standard_no_pad = re_export.standard_no_pad;
pub const url_safe = re_export.url_safe;
pub const url_safe_no_pad = re_export.url_safe_no_pad;

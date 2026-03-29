//! status — HTTP status codes and reason phrases.
//!
//! Mirrors the role of Go's `net/http/status.go`: a shared place for
//! standard status code constants plus a small lookup helper.

pub const @"continue": u16 = 100;
pub const switching_protocols: u16 = 101;
pub const processing: u16 = 102;
pub const early_hints: u16 = 103;

pub const ok: u16 = 200;
pub const created: u16 = 201;
pub const accepted: u16 = 202;
pub const non_authoritative_info: u16 = 203;
pub const no_content: u16 = 204;
pub const reset_content: u16 = 205;
pub const partial_content: u16 = 206;
pub const multi_status: u16 = 207;
pub const already_reported: u16 = 208;
pub const im_used: u16 = 226;

pub const multiple_choices: u16 = 300;
pub const moved_permanently: u16 = 301;
pub const found: u16 = 302;
pub const see_other: u16 = 303;
pub const not_modified: u16 = 304;
pub const use_proxy: u16 = 305;
pub const temporary_redirect: u16 = 307;
pub const permanent_redirect: u16 = 308;

pub const bad_request: u16 = 400;
pub const unauthorized: u16 = 401;
pub const payment_required: u16 = 402;
pub const forbidden: u16 = 403;
pub const not_found: u16 = 404;
pub const method_not_allowed: u16 = 405;
pub const not_acceptable: u16 = 406;
pub const proxy_auth_required: u16 = 407;
pub const request_timeout: u16 = 408;
pub const conflict: u16 = 409;
pub const gone: u16 = 410;
pub const length_required: u16 = 411;
pub const precondition_failed: u16 = 412;
pub const request_entity_too_large: u16 = 413;
pub const request_uri_too_long: u16 = 414;
pub const unsupported_media_type: u16 = 415;
pub const requested_range_not_satisfiable: u16 = 416;
pub const expectation_failed: u16 = 417;
pub const teapot: u16 = 418;
pub const misdirected_request: u16 = 421;
pub const unprocessable_entity: u16 = 422;
pub const locked: u16 = 423;
pub const failed_dependency: u16 = 424;
pub const too_early: u16 = 425;
pub const upgrade_required: u16 = 426;
pub const precondition_required: u16 = 428;
pub const too_many_requests: u16 = 429;
pub const request_header_fields_too_large: u16 = 431;
pub const unavailable_for_legal_reasons: u16 = 451;

pub const internal_server_error: u16 = 500;
pub const not_implemented: u16 = 501;
pub const bad_gateway: u16 = 502;
pub const service_unavailable: u16 = 503;
pub const gateway_timeout: u16 = 504;
pub const http_version_not_supported: u16 = 505;
pub const variant_also_negotiates: u16 = 506;
pub const insufficient_storage: u16 = 507;
pub const loop_detected: u16 = 508;
pub const not_extended: u16 = 510;
pub const network_auth_required: u16 = 511;

pub fn text(code: u16) ?[]const u8 {
    return switch (code) {
        @"continue" => "Continue",
        switching_protocols => "Switching Protocols",
        processing => "Processing",
        early_hints => "Early Hints",

        ok => "OK",
        created => "Created",
        accepted => "Accepted",
        non_authoritative_info => "Non-Authoritative Information",
        no_content => "No Content",
        reset_content => "Reset Content",
        partial_content => "Partial Content",
        multi_status => "Multi-Status",
        already_reported => "Already Reported",
        im_used => "IM Used",

        multiple_choices => "Multiple Choices",
        moved_permanently => "Moved Permanently",
        found => "Found",
        see_other => "See Other",
        not_modified => "Not Modified",
        use_proxy => "Use Proxy",
        temporary_redirect => "Temporary Redirect",
        permanent_redirect => "Permanent Redirect",

        bad_request => "Bad Request",
        unauthorized => "Unauthorized",
        payment_required => "Payment Required",
        forbidden => "Forbidden",
        not_found => "Not Found",
        method_not_allowed => "Method Not Allowed",
        not_acceptable => "Not Acceptable",
        proxy_auth_required => "Proxy Authentication Required",
        request_timeout => "Request Timeout",
        conflict => "Conflict",
        gone => "Gone",
        length_required => "Length Required",
        precondition_failed => "Precondition Failed",
        request_entity_too_large => "Request Entity Too Large",
        request_uri_too_long => "Request URI Too Long",
        unsupported_media_type => "Unsupported Media Type",
        requested_range_not_satisfiable => "Requested Range Not Satisfiable",
        expectation_failed => "Expectation Failed",
        teapot => "I'm a teapot",
        misdirected_request => "Misdirected Request",
        unprocessable_entity => "Unprocessable Entity",
        locked => "Locked",
        failed_dependency => "Failed Dependency",
        too_early => "Too Early",
        upgrade_required => "Upgrade Required",
        precondition_required => "Precondition Required",
        too_many_requests => "Too Many Requests",
        request_header_fields_too_large => "Request Header Fields Too Large",
        unavailable_for_legal_reasons => "Unavailable For Legal Reasons",

        internal_server_error => "Internal Server Error",
        not_implemented => "Not Implemented",
        bad_gateway => "Bad Gateway",
        service_unavailable => "Service Unavailable",
        gateway_timeout => "Gateway Timeout",
        http_version_not_supported => "HTTP Version Not Supported",
        variant_also_negotiates => "Variant Also Negotiates",
        insufficient_storage => "Insufficient Storage",
        loop_detected => "Loop Detected",
        not_extended => "Not Extended",
        network_auth_required => "Network Authentication Required",

        else => null,
    };
}

pub fn isInformational(code: u16) bool {
    return code >= 100 and code < 200;
}

pub fn isSuccess(code: u16) bool {
    return code >= 200 and code < 300;
}

pub fn isRedirect(code: u16) bool {
    return code >= 300 and code < 400;
}

pub fn isClientError(code: u16) bool {
    return code >= 400 and code < 500;
}

pub fn isServerError(code: u16) bool {
    return code >= 500 and code < 600;
}

test "net/unit_tests/http/status/text_returns_reason_phrase_for_common_codes" {
    const std = @import("std");

    try std.testing.expectEqualStrings("OK", text(ok).?);
    try std.testing.expectEqualStrings("No Content", text(no_content).?);
    try std.testing.expectEqualStrings("Not Found", text(not_found).?);
    try std.testing.expect(text(999) == null);
}

test "net/unit_tests/http/status/class_helpers_classify_status_codes" {
    const std = @import("std");

    try std.testing.expect(isInformational(@"continue"));
    try std.testing.expect(isSuccess(ok));
    try std.testing.expect(isRedirect(found));
    try std.testing.expect(isClientError(not_found));
    try std.testing.expect(isServerError(internal_server_error));
}

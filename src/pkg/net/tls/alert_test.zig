const std = @import("std");
const testing = std.testing;
const module = @import("alert.zig");
const test_exports = if (@hasDecl(module, "test_exports")) module.test_exports else struct {};
const Alert = module.Alert;
const AlertLevel = module.AlertLevel;
const AlertDescription = module.AlertDescription;
const AlertError = module.AlertError;
const alertToError = module.alertToError;
const errorToAlert = module.errorToAlert;
const parseAlert = module.parseAlert;
const serializeAlert = module.serializeAlert;
const common = test_exports.common;

test "alert conversion roundtrip" {
    const descriptions = [_]AlertDescription{
        .close_notify,
        .handshake_failure,
        .bad_certificate,
        .internal_error,
    };

    for (descriptions) |desc| {
        const alert_err = alertToError(desc);
        const back = errorToAlert(alert_err);
        try std.testing.expectEqual(desc, back);
    }
}

test "parse and serialize alert" {
    const a = Alert{
        .level = .fatal,
        .description = .handshake_failure,
    };

    var buf: [2]u8 = undefined;
    try serializeAlert(a, &buf);

    const parsed = try parseAlert(&buf);
    try std.testing.expectEqual(a.level, parsed.level);
    try std.testing.expectEqual(a.description, parsed.description);
}

test "alert conversion roundtrip all known descriptions" {
    const all_descriptions = [_]AlertDescription{
        .close_notify,
        .unexpected_message,
        .bad_record_mac,
        .record_overflow,
        .handshake_failure,
        .bad_certificate,
        .unsupported_certificate,
        .certificate_revoked,
        .certificate_expired,
        .certificate_unknown,
        .illegal_parameter,
        .unknown_ca,
        .access_denied,
        .decode_error,
        .decrypt_error,
        .protocol_version,
        .insufficient_security,
        .internal_error,
        .inappropriate_fallback,
        .user_canceled,
        .missing_extension,
        .unsupported_extension,
        .unrecognized_name,
        .bad_certificate_status_response,
        .unknown_psk_identity,
        .certificate_required,
        .no_application_protocol,
    };

    for (all_descriptions) |desc| {
        const err = alertToError(desc);
        const back = errorToAlert(err);
        try std.testing.expectEqual(desc, back);
    }
}

test "unknown alert description maps to UnknownAlert" {
    const unknown: AlertDescription = @enumFromInt(255);
    const err = alertToError(unknown);
    try std.testing.expectEqual(error.UnknownAlert, err);
}

test "UnknownAlert maps to internal_error" {
    const desc = errorToAlert(error.UnknownAlert);
    try std.testing.expectEqual(AlertDescription.internal_error, desc);
}

test "parseAlert too small buffer" {
    const buf: [1]u8 = .{0};
    try std.testing.expectError(error.DecodeError, parseAlert(&buf));
}

test "parseAlert empty buffer" {
    try std.testing.expectError(error.DecodeError, parseAlert(""));
}

test "serializeAlert too small buffer" {
    const a = Alert{ .level = .fatal, .description = .internal_error };
    var buf: [1]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, serializeAlert(a, &buf));
}

test "parse and serialize all alert levels" {
    const levels = [_]AlertLevel{ .warning, .fatal };
    for (levels) |level| {
        const a = Alert{ .level = level, .description = .close_notify };
        var buf: [2]u8 = undefined;
        try serializeAlert(a, &buf);
        const parsed = try parseAlert(&buf);
        try std.testing.expectEqual(level, parsed.level);
    }
}

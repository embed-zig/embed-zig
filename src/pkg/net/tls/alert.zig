const std = @import("std");
const common = @import("common.zig");

pub const Alert = common.Alert;
pub const AlertLevel = common.AlertLevel;
pub const AlertDescription = common.AlertDescription;

pub const AlertError = error{
    CloseNotify,
    UnexpectedMessage,
    BadRecordMac,
    RecordOverflow,
    HandshakeFailure,
    BadCertificate,
    UnsupportedCertificate,
    CertificateRevoked,
    CertificateExpired,
    CertificateUnknown,
    IllegalParameter,
    UnknownCa,
    AccessDenied,
    DecodeError,
    DecryptError,
    ProtocolVersion,
    InsufficientSecurity,
    InternalError,
    InappropriateFallback,
    UserCanceled,
    MissingExtension,
    UnsupportedExtension,
    UnrecognizedName,
    BadCertificateStatusResponse,
    UnknownPskIdentity,
    CertificateRequired,
    NoApplicationProtocol,
    UnknownAlert,
};

pub fn alertToError(description: AlertDescription) AlertError {
    return switch (description) {
        .close_notify => error.CloseNotify,
        .unexpected_message => error.UnexpectedMessage,
        .bad_record_mac => error.BadRecordMac,
        .record_overflow => error.RecordOverflow,
        .handshake_failure => error.HandshakeFailure,
        .bad_certificate => error.BadCertificate,
        .unsupported_certificate => error.UnsupportedCertificate,
        .certificate_revoked => error.CertificateRevoked,
        .certificate_expired => error.CertificateExpired,
        .certificate_unknown => error.CertificateUnknown,
        .illegal_parameter => error.IllegalParameter,
        .unknown_ca => error.UnknownCa,
        .access_denied => error.AccessDenied,
        .decode_error => error.DecodeError,
        .decrypt_error => error.DecryptError,
        .protocol_version => error.ProtocolVersion,
        .insufficient_security => error.InsufficientSecurity,
        .internal_error => error.InternalError,
        .inappropriate_fallback => error.InappropriateFallback,
        .user_canceled => error.UserCanceled,
        .missing_extension => error.MissingExtension,
        .unsupported_extension => error.UnsupportedExtension,
        .unrecognized_name => error.UnrecognizedName,
        .bad_certificate_status_response => error.BadCertificateStatusResponse,
        .unknown_psk_identity => error.UnknownPskIdentity,
        .certificate_required => error.CertificateRequired,
        .no_application_protocol => error.NoApplicationProtocol,
        else => error.UnknownAlert,
    };
}

pub fn errorToAlert(err: AlertError) AlertDescription {
    return switch (err) {
        error.CloseNotify => .close_notify,
        error.UnexpectedMessage => .unexpected_message,
        error.BadRecordMac => .bad_record_mac,
        error.RecordOverflow => .record_overflow,
        error.HandshakeFailure => .handshake_failure,
        error.BadCertificate => .bad_certificate,
        error.UnsupportedCertificate => .unsupported_certificate,
        error.CertificateRevoked => .certificate_revoked,
        error.CertificateExpired => .certificate_expired,
        error.CertificateUnknown => .certificate_unknown,
        error.IllegalParameter => .illegal_parameter,
        error.UnknownCa => .unknown_ca,
        error.AccessDenied => .access_denied,
        error.DecodeError => .decode_error,
        error.DecryptError => .decrypt_error,
        error.ProtocolVersion => .protocol_version,
        error.InsufficientSecurity => .insufficient_security,
        error.InternalError => .internal_error,
        error.InappropriateFallback => .inappropriate_fallback,
        error.UserCanceled => .user_canceled,
        error.MissingExtension => .missing_extension,
        error.UnsupportedExtension => .unsupported_extension,
        error.UnrecognizedName => .unrecognized_name,
        error.BadCertificateStatusResponse => .bad_certificate_status_response,
        error.UnknownPskIdentity => .unknown_psk_identity,
        error.CertificateRequired => .certificate_required,
        error.NoApplicationProtocol => .no_application_protocol,
        error.UnknownAlert => .internal_error,
    };
}

pub fn parseAlert(data: []const u8) !Alert {
    if (data.len < 2) return error.DecodeError;
    return Alert{
        .level = @enumFromInt(data[0]),
        .description = @enumFromInt(data[1]),
    };
}

pub fn serializeAlert(a: Alert, buf: []u8) !void {
    if (buf.len < 2) return error.BufferTooSmall;
    buf[0] = @intFromEnum(a.level);
    buf[1] = @intFromEnum(a.description);
}

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

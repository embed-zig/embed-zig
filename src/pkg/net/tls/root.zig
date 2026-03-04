const std = @import("std");

pub const common = @import("common.zig");
pub const record = @import("record.zig");
pub const handshake = @import("handshake.zig");
pub const alert = @import("alert.zig");
pub const extensions = @import("extensions.zig");
pub const client = @import("client.zig");
pub const stream = @import("stream.zig");
pub const kdf = @import("kdf.zig");

pub const Client = client.Client;
pub const Config = client.Config;
pub const Stream = stream.Stream;

pub const ProtocolVersion = common.ProtocolVersion;
pub const CipherSuite = common.CipherSuite;
pub const ContentType = common.ContentType;
pub const HandshakeType = common.HandshakeType;
pub const NamedGroup = common.NamedGroup;
pub const SignatureScheme = common.SignatureScheme;
pub const Alert = common.Alert;
pub const AlertLevel = common.AlertLevel;
pub const AlertDescription = common.AlertDescription;

pub const MAX_PLAINTEXT_LEN = common.MAX_PLAINTEXT_LEN;
pub const MAX_CIPHERTEXT_LEN = common.MAX_CIPHERTEXT_LEN;
pub const RECORD_HEADER_LEN = common.RECORD_HEADER_LEN;

pub const connect = client.connect;

pub const Error = error{
    NotConnected,
    ConnectionClosed,
    AlertReceived,
    UnexpectedMessage,
    HandshakeFailed,
    OutOfMemory,
    BufferTooSmall,
    InvalidHandshake,
    UnsupportedGroup,
    InvalidPublicKey,
    HelloRetryNotSupported,
    UnsupportedCipherSuite,
    InvalidKeyLength,
    InvalidIvLength,
    RecordTooLarge,
    DecryptionFailed,
    BadRecordMac,
    UnexpectedRecord,
    IdentityElement,
    CertificateVerificationFailed,
};

pub const stress_test = @import("stress_test.zig");

test {
    _ = common;
    _ = record;
    _ = handshake;
    _ = alert;
    _ = extensions;
    _ = client;
    _ = stream;
    _ = kdf;
    _ = stress_test;
}

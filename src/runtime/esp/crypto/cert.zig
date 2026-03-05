//! X.509 certificate support - ESP32 mbedTLS implementation.
//!
//! Certificate parsing, verification, and chain validation using mbedTLS.

const std = @import("std");
const mbed = @import("esp").mbedtls.mbed_tls;

pub const CaStore = union(enum) {
    roots: []const []const u8,
    custom: []const u8,
    self_signed,
    insecure,
    esp_bundle,
};

pub const ChainError = error{
    EmptyChain,
    ChainTooLong,
    CertificateExpired,
    CertificateNotYetValid,
    IssuerMismatch,
    SignatureInvalid,
    UntrustedRoot,
    HostnameMismatch,
    ParseError,
};

pub const MAX_CHAIN_DEPTH = 10;

pub fn verifyChain(
    cert_chain: []const []const u8,
    hostname: ?[]const u8,
    ca_store: CaStore,
    now_sec: i64,
) ChainError!void {
    _ = now_sec;

    if (cert_chain.len == 0) return error.EmptyChain;
    if (cert_chain.len > MAX_CHAIN_DEPTH) return error.ChainTooLong;

    switch (ca_store) {
        .insecure => return,
        .self_signed => {
            var crt: mbed.x509_crt = undefined;
            mbed.x509_crt_init(&crt);
            defer mbed.x509_crt_free(&crt);

            if (mbed.x509_crt_parse_der(&crt, cert_chain[0].ptr, cert_chain[0].len) != 0)
                return error.ParseError;

            var flags: u32 = 0;
            if (mbed.x509_crt_verify(&crt, &crt, null, null, &flags, null, null) != 0)
                return error.SignatureInvalid;
        },
        .custom => |ca_der| {
            return verifyChainWithCa(cert_chain, hostname, ca_der);
        },
        .roots => |root_cas| {
            for (root_cas) |root_der| {
                if (verifyChainWithCa(cert_chain, hostname, root_der)) |_| {
                    return;
                } else |_| {
                    continue;
                }
            }
            return error.UntrustedRoot;
        },
        .esp_bundle => {
            return error.UntrustedRoot;
        },
    }
}

fn verifyChainWithCa(
    cert_chain: []const []const u8,
    hostname: ?[]const u8,
    ca_der: []const u8,
) ChainError!void {
    _ = hostname;

    var ca_crt: mbed.x509_crt = undefined;
    var crt: mbed.x509_crt = undefined;

    mbed.x509_crt_init(&ca_crt);
    mbed.x509_crt_init(&crt);
    defer {
        mbed.x509_crt_free(&ca_crt);
        mbed.x509_crt_free(&crt);
    }

    if (mbed.x509_crt_parse_der(&ca_crt, ca_der.ptr, ca_der.len) != 0)
        return error.ParseError;

    for (cert_chain) |cert_der| {
        if (mbed.x509_crt_parse_der(&crt, cert_der.ptr, cert_der.len) != 0)
            return error.ParseError;
    }

    var flags: u32 = 0;
    if (mbed.x509_crt_verify(&crt, &ca_crt, null, null, &flags, null, null) != 0) {
        if (flags & 0x01 != 0) return error.CertificateExpired;
        if (flags & 0x02 != 0) return error.CertificateNotYetValid;
        if (flags & 0x08 != 0) return error.UntrustedRoot;
        return error.SignatureInvalid;
    }
}

pub fn verifyCertificate(
    cert_der: []const u8,
    hostname: ?[]const u8,
    ca_store: CaStore,
    now_sec: i64,
) ChainError!void {
    const single_chain = [_][]const u8{cert_der};
    return verifyChain(&single_chain, hostname, ca_store, now_sec);
}

pub const Cert = struct {
    crt: mbed.x509_crt,

    pub fn init() Cert {
        var self: Cert = undefined;
        mbed.x509_crt_init(&self.crt);
        return self;
    }

    pub fn deinit(self: *Cert) void {
        mbed.x509_crt_free(&self.crt);
    }

    pub fn parseDer(self: *Cert, der: []const u8) !void {
        if (mbed.x509_crt_parse_der(&self.crt, der.ptr, der.len) != 0)
            return error.ParseError;
    }

    pub fn parsePem(self: *Cert, pem: []const u8) !void {
        if (mbed.x509_crt_parse(&self.crt, pem.ptr, pem.len) != 0)
            return error.ParseError;
    }
};

pub const Parsed = Cert;

pub fn parseDer(der: []const u8) !Cert {
    var crt = Cert.init();
    try crt.parseDer(der);
    return crt;
}

pub fn parsePem(pem: []const u8) !Cert {
    var crt = Cert.init();
    try crt.parsePem(pem);
    return crt;
}

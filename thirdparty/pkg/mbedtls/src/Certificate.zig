const std = @import("std");
const builtin = @import("builtin");
const EcdsaP256Sha256 = @import("sign/ecdsa.zig").EcdsaP256Sha256;
const EcdsaP384Sha384 = @import("sign/ecdsa.zig").EcdsaP384Sha384;
const Sha256 = @import("hash/sha2.zig").Sha256;
const Sha384 = @import("hash/sha2.zig").Sha384;
const Sha512 = @import("hash/sha2.zig").Sha512;
const psa_key = @import("binding/psa/key.zig");
const psa_types = @import("binding/psa/types.zig");
const shared = @import("shared.zig");

const Certificate = @This();
const Allocator = std.mem.Allocator;
const base64 = std.base64.standard.decoderWithIgnore(" \t\r\n");
const fs = std.fs;
const mem = std.mem;

buffer: []const u8,
index: u32,

pub const Bundle = struct {
    map: std.HashMapUnmanaged(der.Element.Slice, u32, MapContext, std.hash_map.default_max_load_percentage) = .empty,
    bytes: std.ArrayListUnmanaged(u8) = .empty,

    pub const VerifyError = Parsed.VerifyError || ParseError || error{CertificateIssuerNotFound};

    pub fn verify(cb: Bundle, subject: Parsed, now_sec: i64) VerifyError!void {
        const bytes_index = cb.find(subject.issuer()) orelse return error.CertificateIssuerNotFound;
        const issuer_cert: Certificate = .{ .buffer = cb.bytes.items, .index = bytes_index };
        const issuer = try issuer_cert.parse();
        try subject.verify(issuer, now_sec);
    }

    pub fn find(cb: Bundle, subject_name: []const u8) ?u32 {
        const Adapter = struct {
            cb: Bundle,

            pub fn hash(ctx: @This(), k: []const u8) u64 {
                _ = ctx;
                return std.hash_map.hashString(k);
            }

            pub fn eql(ctx: @This(), a: []const u8, b_key: der.Element.Slice) bool {
                return mem.eql(u8, a, ctx.cb.bytes.items[b_key.start..b_key.end]);
            }
        };
        return cb.map.getAdapted(subject_name, Adapter{ .cb = cb });
    }

    pub fn deinit(cb: *Bundle, gpa: Allocator) void {
        cb.map.deinit(gpa);
        cb.bytes.deinit(gpa);
        cb.* = undefined;
    }

    pub fn rescan(cb: *Bundle, gpa: Allocator) !void {
        cb.bytes.clearRetainingCapacity();
        cb.map.clearRetainingCapacity();

        const linux_cert_file_paths = [_][]const u8{
            "/etc/ssl/certs/ca-certificates.crt",
            "/etc/pki/tls/certs/ca-bundle.crt",
            "/etc/ssl/ca-bundle.pem",
            "/etc/pki/tls/cacert.pem",
            "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem",
            "/etc/ssl/cert.pem",
        };
        const cert_file_paths: []const []const u8 = switch (builtin.os.tag) {
            .linux => &linux_cert_file_paths,
            .macos, .freebsd, .openbsd => &.{"/etc/ssl/cert.pem"},
            else => &.{},
        };
        for (cert_file_paths) |path| {
            addCertsFromFilePathAbsolute(cb, gpa, path) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => |e| return e,
            };
            break;
        }
    }

    pub fn addCertsFromFilePathAbsolute(cb: *Bundle, gpa: Allocator, abs_file_path: []const u8) !void {
        var file = try fs.openFileAbsolute(abs_file_path, .{});
        defer file.close();
        try addCertsFromFile(cb, gpa, file);
    }

    pub fn addCertsFromFile(cb: *Bundle, gpa: Allocator, file: fs.File) !void {
        const encoded_bytes = try file.readToEndAlloc(gpa, 16 * 1024 * 1024);
        defer gpa.free(encoded_bytes);
        try addCertsFromPemBytes(cb, gpa, encoded_bytes);
    }

    pub fn addCertsFromPemBytes(cb: *Bundle, gpa: Allocator, encoded_bytes: []const u8) !void {
        const begin_marker = "-----BEGIN CERTIFICATE-----";
        const end_marker = "-----END CERTIFICATE-----";
        const now_sec = std.time.timestamp();

        var start_index: usize = 0;
        while (mem.indexOfPos(u8, encoded_bytes, start_index, begin_marker)) |begin_marker_start| {
            const cert_start = begin_marker_start + begin_marker.len;
            const cert_end = mem.indexOfPos(u8, encoded_bytes, cert_start, end_marker) orelse return error.MissingEndCertificateMarker;
            start_index = cert_end + end_marker.len;

            const encoded_cert = mem.trim(u8, encoded_bytes[cert_start..cert_end], " \t\r\n");
            const decoded_size_upper_bound = encoded_cert.len / 4 * 3 + 3;
            try cb.bytes.ensureUnusedCapacity(gpa, decoded_size_upper_bound);
            const decoded_start: u32 = @intCast(cb.bytes.items.len);
            const dest = cb.bytes.allocatedSlice()[decoded_start..][0..decoded_size_upper_bound];
            const decoded_len = try base64.decode(dest, encoded_cert);
            cb.bytes.items.len += decoded_len;
            try cb.parseCert(gpa, decoded_start, now_sec);
        }
    }

    pub fn parseCert(cb: *Bundle, gpa: Allocator, decoded_start: u32, now_sec: i64) (Allocator.Error || ParseError)!void {
        const cert: Certificate = .{ .buffer = cb.bytes.items, .index = decoded_start };
        const parsed = cert.parse() catch |err| switch (err) {
            error.CertificateHasUnrecognizedObjectId => {
                cb.bytes.items.len = decoded_start;
                return;
            },
            else => |e| return e,
        };
        if (now_sec > parsed.validity.not_after) {
            cb.bytes.items.len = decoded_start;
            return;
        }
        const gop = try cb.map.getOrPutContext(gpa, parsed.subject_slice, .{ .cb = cb });
        if (gop.found_existing) {
            cb.bytes.items.len = decoded_start;
        } else {
            gop.value_ptr.* = decoded_start;
        }
    }
};

pub const Version = enum { v1, v2, v3 };

pub const Algorithm = enum {
    sha1WithRSAEncryption,
    sha224WithRSAEncryption,
    sha256WithRSAEncryption,
    sha384WithRSAEncryption,
    sha512WithRSAEncryption,
    ecdsa_with_SHA224,
    ecdsa_with_SHA256,
    ecdsa_with_SHA384,
    ecdsa_with_SHA512,
    md2WithRSAEncryption,
    md5WithRSAEncryption,
    curveEd25519,

    pub const map = std.StaticStringMap(Algorithm).initComptime(.{
        .{ &.{ 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x05 }, .sha1WithRSAEncryption },
        .{ &.{ 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B }, .sha256WithRSAEncryption },
        .{ &.{ 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0C }, .sha384WithRSAEncryption },
        .{ &.{ 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0D }, .sha512WithRSAEncryption },
        .{ &.{ 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0E }, .sha224WithRSAEncryption },
        .{ &.{ 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x01 }, .ecdsa_with_SHA224 },
        .{ &.{ 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02 }, .ecdsa_with_SHA256 },
        .{ &.{ 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x03 }, .ecdsa_with_SHA384 },
        .{ &.{ 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x04 }, .ecdsa_with_SHA512 },
        .{ &.{ 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x02 }, .md2WithRSAEncryption },
        .{ &.{ 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x04 }, .md5WithRSAEncryption },
        .{ &.{ 0x2B, 0x65, 0x70 }, .curveEd25519 },
    });
};

pub const AlgorithmCategory = enum {
    rsaEncryption,
    rsassa_pss,
    X9_62_id_ecPublicKey,
    curveEd25519,

    pub const map = std.StaticStringMap(AlgorithmCategory).initComptime(.{
        .{ &.{ 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01 }, .rsaEncryption },
        .{ &.{ 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0A }, .rsassa_pss },
        .{ &.{ 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01 }, .X9_62_id_ecPublicKey },
        .{ &.{ 0x2B, 0x65, 0x70 }, .curveEd25519 },
    });
};

pub const Attribute = enum {
    commonName,
    serialNumber,
    countryName,
    localityName,
    stateOrProvinceName,
    streetAddress,
    organizationName,
    organizationalUnitName,
    postalCode,
    organizationIdentifier,
    pkcs9_emailAddress,
    domainComponent,

    pub const map = std.StaticStringMap(Attribute).initComptime(.{
        .{ &.{ 0x55, 0x04, 0x03 }, .commonName },
        .{ &.{ 0x55, 0x04, 0x05 }, .serialNumber },
        .{ &.{ 0x55, 0x04, 0x06 }, .countryName },
        .{ &.{ 0x55, 0x04, 0x07 }, .localityName },
        .{ &.{ 0x55, 0x04, 0x08 }, .stateOrProvinceName },
        .{ &.{ 0x55, 0x04, 0x09 }, .streetAddress },
        .{ &.{ 0x55, 0x04, 0x0A }, .organizationName },
        .{ &.{ 0x55, 0x04, 0x0B }, .organizationalUnitName },
        .{ &.{ 0x55, 0x04, 0x11 }, .postalCode },
        .{ &.{ 0x55, 0x04, 0x61 }, .organizationIdentifier },
        .{ &.{ 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x01 }, .pkcs9_emailAddress },
        .{ &.{ 0x09, 0x92, 0x26, 0x89, 0x93, 0xF2, 0x2C, 0x64, 0x01, 0x19 }, .domainComponent },
    });
};

pub const NamedCurve = enum {
    secp384r1,
    secp521r1,
    X9_62_prime256v1,

    pub const map = std.StaticStringMap(NamedCurve).initComptime(.{
        .{ &.{ 0x2B, 0x81, 0x04, 0x00, 0x22 }, .secp384r1 },
        .{ &.{ 0x2B, 0x81, 0x04, 0x00, 0x23 }, .secp521r1 },
        .{ &.{ 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07 }, .X9_62_prime256v1 },
    });
};

pub const ExtensionId = enum {
    subject_key_identifier,
    key_usage,
    private_key_usage_period,
    subject_alt_name,
    issuer_alt_name,
    basic_constraints,
    crl_number,
    certificate_policies,
    authority_key_identifier,
    msCertsrvCAVersion,
    commonName,
    ext_key_usage,
    crl_distribution_points,
    info_access,
    entrustVersInfo,
    enroll_certtype,
    pe_logotype,
    netscape_cert_type,
    netscape_comment,

    pub const map = std.StaticStringMap(ExtensionId).initComptime(.{
        .{ &.{ 0x55, 0x04, 0x03 }, .commonName },
        .{ &.{ 0x55, 0x1D, 0x01 }, .authority_key_identifier },
        .{ &.{ 0x55, 0x1D, 0x07 }, .subject_alt_name },
        .{ &.{ 0x55, 0x1D, 0x0E }, .subject_key_identifier },
        .{ &.{ 0x55, 0x1D, 0x0F }, .key_usage },
        .{ &.{ 0x55, 0x1D, 0x0A }, .basic_constraints },
        .{ &.{ 0x55, 0x1D, 0x10 }, .private_key_usage_period },
        .{ &.{ 0x55, 0x1D, 0x11 }, .subject_alt_name },
        .{ &.{ 0x55, 0x1D, 0x12 }, .issuer_alt_name },
        .{ &.{ 0x55, 0x1D, 0x13 }, .basic_constraints },
        .{ &.{ 0x55, 0x1D, 0x14 }, .crl_number },
        .{ &.{ 0x55, 0x1D, 0x1F }, .crl_distribution_points },
        .{ &.{ 0x55, 0x1D, 0x20 }, .certificate_policies },
        .{ &.{ 0x55, 0x1D, 0x23 }, .authority_key_identifier },
        .{ &.{ 0x55, 0x1D, 0x25 }, .ext_key_usage },
        .{ &.{ 0x2B, 0x06, 0x01, 0x04, 0x01, 0x82, 0x37, 0x15, 0x01 }, .msCertsrvCAVersion },
        .{ &.{ 0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x01, 0x01 }, .info_access },
        .{ &.{ 0x2A, 0x86, 0x48, 0x86, 0xF6, 0x7D, 0x07, 0x41, 0x00 }, .entrustVersInfo },
        .{ &.{ 0x2B, 0x06, 0x01, 0x04, 0x01, 0x82, 0x37, 0x14, 0x02 }, .enroll_certtype },
        .{ &.{ 0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x01, 0x0C }, .pe_logotype },
        .{ &.{ 0x60, 0x86, 0x48, 0x01, 0x86, 0xF8, 0x42, 0x01, 0x01 }, .netscape_cert_type },
        .{ &.{ 0x60, 0x86, 0x48, 0x01, 0x86, 0xF8, 0x42, 0x01, 0x0D }, .netscape_comment },
    });
};

pub const GeneralNameTag = enum(u5) {
    otherName = 0,
    rfc822Name = 1,
    dNSName = 2,
    x400Address = 3,
    directoryName = 4,
    ediPartyName = 5,
    uniformResourceIdentifier = 6,
    iPAddress = 7,
    registeredID = 8,
    _,
};

pub const Parsed = struct {
    certificate: Certificate,
    issuer_slice: Slice,
    subject_slice: Slice,
    common_name_slice: Slice,
    signature_slice: Slice,
    signature_algorithm: Algorithm,
    pub_key_algo: PubKeyAlgo,
    pub_key_slice: Slice,
    message_slice: Slice,
    subject_alt_name_slice: Slice,
    validity: Validity,
    version: Version,

    pub const PubKeyAlgo = union(AlgorithmCategory) {
        rsaEncryption: void,
        rsassa_pss: void,
        X9_62_id_ecPublicKey: NamedCurve,
        curveEd25519: void,
    };

    pub const Validity = struct {
        not_before: u64,
        not_after: u64,
    };

    pub const Slice = der.Element.Slice;

    pub fn slice(p: Parsed, s: Slice) []const u8 {
        return p.certificate.buffer[s.start..s.end];
    }

    pub fn issuer(p: Parsed) []const u8 {
        return p.slice(p.issuer_slice);
    }

    pub fn subject(p: Parsed) []const u8 {
        return p.slice(p.subject_slice);
    }

    pub fn commonName(p: Parsed) []const u8 {
        return p.slice(p.common_name_slice);
    }

    pub fn signature(p: Parsed) []const u8 {
        return p.slice(p.signature_slice);
    }

    pub fn pubKey(p: Parsed) []const u8 {
        return p.slice(p.pub_key_slice);
    }

    pub fn message(p: Parsed) []const u8 {
        return p.slice(p.message_slice);
    }

    pub fn subjectAltName(p: Parsed) []const u8 {
        return p.slice(p.subject_alt_name_slice);
    }

    pub const VerifyError = error{
        CertificateIssuerMismatch,
        CertificateNotYetValid,
        CertificateExpired,
        CertificateSignatureAlgorithmUnsupported,
        CertificateSignatureAlgorithmMismatch,
        CertificateFieldHasInvalidLength,
        CertificateFieldHasWrongDataType,
        CertificatePublicKeyInvalid,
        CertificateSignatureInvalidLength,
        CertificateSignatureInvalid,
        CertificateSignatureUnsupportedBitCount,
        CertificateSignatureNamedCurveUnsupported,
    };

    pub fn verify(parsed_subject: Parsed, parsed_issuer: Parsed, now_sec: i64) VerifyError!void {
        if (!mem.eql(u8, parsed_subject.issuer(), parsed_issuer.subject())) {
            return error.CertificateIssuerMismatch;
        }
        if (now_sec < parsed_subject.validity.not_before) return error.CertificateNotYetValid;
        if (now_sec > parsed_subject.validity.not_after) return error.CertificateExpired;

        switch (parsed_subject.signature_algorithm) {
            .sha256WithRSAEncryption,
            .sha384WithRSAEncryption,
            .sha512WithRSAEncryption,
            => return verifyRsa(parsed_subject.signature_algorithm, parsed_subject.message(), parsed_subject.signature(), parsed_issuer.pub_key_algo, parsed_issuer.pubKey()),
            .ecdsa_with_SHA256,
            .ecdsa_with_SHA384,
            => return verifyEcdsa(parsed_subject.signature_algorithm, parsed_subject.message(), parsed_subject.signature(), parsed_issuer.pub_key_algo, parsed_issuer.pubKey()),
            else => return error.CertificateSignatureAlgorithmUnsupported,
        }
    }

    pub const VerifyHostNameError = error{
        CertificateHostMismatch,
        CertificateFieldHasInvalidLength,
    };

    pub fn verifyHostName(parsed_subject: Parsed, host_name: []const u8) VerifyHostNameError!void {
        const subject_alt_name = parsed_subject.subjectAltName();
        if (subject_alt_name.len == 0) {
            if (checkHostName(host_name, parsed_subject.commonName())) return;
            return error.CertificateHostMismatch;
        }

        const general_names = try der.Element.parse(subject_alt_name, 0);
        var name_i = general_names.slice.start;
        while (name_i < general_names.slice.end) {
            const general_name = try der.Element.parse(subject_alt_name, name_i);
            name_i = general_name.slice.end;
            switch (@as(GeneralNameTag, @enumFromInt(@intFromEnum(general_name.identifier.tag)))) {
                .dNSName => {
                    const dns_name = subject_alt_name[general_name.slice.start..general_name.slice.end];
                    if (checkHostName(host_name, dns_name)) return;
                },
                else => {},
            }
        }
        return error.CertificateHostMismatch;
    }

    fn checkHostName(host_name: []const u8, dns_name: []const u8) bool {
        if (host_name.len == 0 or dns_name.len == 0) return false;
        if (std.ascii.eqlIgnoreCase(dns_name, host_name)) return true;
        if (dns_name.len >= 3 and mem.startsWith(u8, dns_name, "*.")) {
            const wildcard_suffix = dns_name[2..];
            if (mem.indexOf(u8, wildcard_suffix, "*") != null) return false;
            const dot_pos = mem.indexOf(u8, host_name, ".") orelse return false;
            return std.ascii.eqlIgnoreCase(wildcard_suffix, host_name[dot_pos + 1 ..]);
        }
        return false;
    }
};

pub const ParseError = der.Element.ParseError || ParseVersionError || ParseTimeError || ParseEnumError || ParseBitStringError;

pub fn parse(cert: Certificate) ParseError!Parsed {
    const cert_bytes = cert.buffer;
    const certificate = try der.Element.parse(cert_bytes, cert.index);
    const tbs_certificate = try der.Element.parse(cert_bytes, certificate.slice.start);
    const version_elem = try der.Element.parse(cert_bytes, tbs_certificate.slice.start);
    const version = try parseVersion(cert_bytes, version_elem);
    const serial_number = if (@as(u8, @bitCast(version_elem.identifier)) == 0xa0)
        try der.Element.parse(cert_bytes, version_elem.slice.end)
    else
        version_elem;
    const tbs_signature = try der.Element.parse(cert_bytes, serial_number.slice.end);
    const issuer = try der.Element.parse(cert_bytes, tbs_signature.slice.end);
    const validity = try der.Element.parse(cert_bytes, issuer.slice.end);
    const not_before = try der.Element.parse(cert_bytes, validity.slice.start);
    const not_before_utc = try parseTime(cert, not_before);
    const not_after = try der.Element.parse(cert_bytes, not_before.slice.end);
    const not_after_utc = try parseTime(cert, not_after);
    const subject = try der.Element.parse(cert_bytes, validity.slice.end);
    const pub_key_info = try der.Element.parse(cert_bytes, subject.slice.end);
    const pub_key_signature_algorithm = try der.Element.parse(cert_bytes, pub_key_info.slice.start);
    const pub_key_algo_elem = try der.Element.parse(cert_bytes, pub_key_signature_algorithm.slice.start);
    const pub_key_algo: Parsed.PubKeyAlgo = switch (try parseAlgorithmCategory(cert_bytes, pub_key_algo_elem)) {
        .X9_62_id_ecPublicKey => pub_key_algo: {
            const params_elem = try der.Element.parse(cert_bytes, pub_key_algo_elem.slice.end);
            break :pub_key_algo .{ .X9_62_id_ecPublicKey = try parseNamedCurve(cert_bytes, params_elem) };
        },
        inline else => |tag| @unionInit(Parsed.PubKeyAlgo, @tagName(tag), {}),
    };
    const pub_key_elem = try der.Element.parse(cert_bytes, pub_key_signature_algorithm.slice.end);
    const pub_key = try parseBitString(cert, pub_key_elem);

    var common_name = der.Element.Slice.empty;
    var name_i = subject.slice.start;
    while (name_i < subject.slice.end) {
        const rdn = try der.Element.parse(cert_bytes, name_i);
        var rdn_i = rdn.slice.start;
        while (rdn_i < rdn.slice.end) {
            const atav = try der.Element.parse(cert_bytes, rdn_i);
            var atav_i = atav.slice.start;
            while (atav_i < atav.slice.end) {
                const ty_elem = try der.Element.parse(cert_bytes, atav_i);
                const val = try der.Element.parse(cert_bytes, ty_elem.slice.end);
                atav_i = val.slice.end;
                const ty = parseAttribute(cert_bytes, ty_elem) catch |err| switch (err) {
                    error.CertificateHasUnrecognizedObjectId => continue,
                    else => |e| return e,
                };
                if (ty == .commonName) common_name = val.slice;
            }
            rdn_i = atav.slice.end;
        }
        name_i = rdn.slice.end;
    }

    const sig_algo = try der.Element.parse(cert_bytes, tbs_certificate.slice.end);
    const algo_elem = try der.Element.parse(cert_bytes, sig_algo.slice.start);
    const signature_algorithm = try parseAlgorithm(cert_bytes, algo_elem);
    const sig_elem = try der.Element.parse(cert_bytes, sig_algo.slice.end);
    const signature = try parseBitString(cert, sig_elem);

    var subject_alt_name_slice = der.Element.Slice.empty;
    ext: {
        if (version == .v1 or pub_key_info.slice.end >= tbs_certificate.slice.end) break :ext;
        const outer_extensions = try der.Element.parse(cert_bytes, pub_key_info.slice.end);
        if (@as(u8, @bitCast(outer_extensions.identifier)) != 0xa3) break :ext;
        const extensions = try der.Element.parse(cert_bytes, outer_extensions.slice.start);
        var ext_i = extensions.slice.start;
        while (ext_i < extensions.slice.end) {
            const extension = try der.Element.parse(cert_bytes, ext_i);
            ext_i = extension.slice.end;
            const oid_elem = try der.Element.parse(cert_bytes, extension.slice.start);
            const ext_id = parseExtensionId(cert_bytes, oid_elem) catch |err| switch (err) {
                error.CertificateHasUnrecognizedObjectId => continue,
                else => |e| return e,
            };
            const critical_elem = try der.Element.parse(cert_bytes, oid_elem.slice.end);
            const ext_bytes_elem = if (critical_elem.identifier.tag != .boolean)
                critical_elem
            else
                try der.Element.parse(cert_bytes, critical_elem.slice.end);
            if (ext_id == .subject_alt_name) subject_alt_name_slice = ext_bytes_elem.slice;
        }
    }

    return .{
        .certificate = cert,
        .common_name_slice = common_name,
        .issuer_slice = issuer.slice,
        .subject_slice = subject.slice,
        .signature_slice = signature,
        .signature_algorithm = signature_algorithm,
        .message_slice = .{ .start = certificate.slice.start, .end = tbs_certificate.slice.end },
        .pub_key_algo = pub_key_algo,
        .pub_key_slice = pub_key,
        .validity = .{ .not_before = not_before_utc, .not_after = not_after_utc },
        .subject_alt_name_slice = subject_alt_name_slice,
        .version = version,
    };
}

pub fn verify(subject: Certificate, issuer: Certificate, now_sec: i64) !void {
    const parsed_subject = try subject.parse();
    const parsed_issuer = try issuer.parse();
    return parsed_subject.verify(parsed_issuer, now_sec);
}

pub const ParseBitStringError = error{ CertificateFieldHasWrongDataType, CertificateHasInvalidBitString };

pub fn parseBitString(cert: Certificate, elem: der.Element) ParseBitStringError!der.Element.Slice {
    if (elem.identifier.tag != .bitstring) return error.CertificateFieldHasWrongDataType;
    if (cert.buffer[elem.slice.start] != 0) return error.CertificateHasInvalidBitString;
    return .{ .start = elem.slice.start + 1, .end = elem.slice.end };
}

pub const ParseTimeError = error{ CertificateTimeInvalid, CertificateFieldHasWrongDataType };

pub fn parseTime(cert: Certificate, elem: der.Element) ParseTimeError!u64 {
    const bytes = cert.buffer[elem.slice.start..elem.slice.end];
    switch (elem.identifier.tag) {
        .utc_time => {
            if (bytes.len != "YYMMDDHHMMSSZ".len or bytes[12] != 'Z') return error.CertificateTimeInvalid;
            const yy: u16 = try parseTimeDigits(bytes[0..2], 0, 99);
            const year: u16 = if (yy >= 50) 1900 + yy else 2000 + yy;
            return epochSeconds(year, try parseMonth(bytes[2..4]), try parseDay(bytes[4..6]), try parseHour(bytes[6..8]), try parseMinute(bytes[8..10]), try parseSecond(bytes[10..12]));
        },
        .generalized_time => {
            if (bytes.len != "YYYYMMDDHHMMSSZ".len or bytes[14] != 'Z') return error.CertificateTimeInvalid;
            return epochSeconds(try parseYear4(bytes[0..4]), try parseMonth(bytes[4..6]), try parseDay(bytes[6..8]), try parseHour(bytes[8..10]), try parseMinute(bytes[10..12]), try parseSecond(bytes[12..14]));
        },
        else => return error.CertificateFieldHasWrongDataType,
    }
}

fn parseMonth(text: *const [2]u8) !u8 {
    return parseTimeDigits(text, 1, 12);
}

fn parseDay(text: *const [2]u8) !u8 {
    return parseTimeDigits(text, 1, 31);
}

fn parseHour(text: *const [2]u8) !u8 {
    return parseTimeDigits(text, 0, 23);
}

fn parseMinute(text: *const [2]u8) !u8 {
    return parseTimeDigits(text, 0, 59);
}

fn parseSecond(text: *const [2]u8) !u8 {
    return parseTimeDigits(text, 0, 59);
}

pub fn parseTimeDigits(text: *const [2]u8, min: u8, max: u8) !u8 {
    if (!std.ascii.isDigit(text[0]) or !std.ascii.isDigit(text[1])) return error.CertificateTimeInvalid;
    const value = (text[0] - '0') * 10 + (text[1] - '0');
    if (value < min or value > max) return error.CertificateTimeInvalid;
    return value;
}

pub fn parseYear4(text: *const [4]u8) !u16 {
    const century = try parseTimeDigits(text[0..2], 0, 99);
    const year = try parseTimeDigits(text[2..4], 0, 99);
    return @as(u16, century) * 100 + year;
}

fn epochSeconds(year: u16, month: u8, day: u8, hour: u8, minute: u8, second: u8) u64 {
    var days: u64 = 0;
    var y: u16 = std.time.epoch.epoch_year;
    while (y < year) : (y += 1) {
        days += std.time.epoch.getDaysInYear(y);
    }
    var m: u8 = 1;
    while (m < month) : (m += 1) {
        days += std.time.epoch.getDaysInMonth(year, @enumFromInt(m));
    }
    days += day - 1;
    return days * std.time.epoch.secs_per_day + @as(u64, hour) * 3600 + @as(u64, minute) * 60 + second;
}

pub const ParseEnumError = error{ CertificateFieldHasWrongDataType, CertificateHasUnrecognizedObjectId };

pub fn parseAlgorithm(bytes: []const u8, element: der.Element) ParseEnumError!Algorithm {
    return parseEnum(Algorithm, bytes, element);
}

pub fn parseAlgorithmCategory(bytes: []const u8, element: der.Element) ParseEnumError!AlgorithmCategory {
    return parseEnum(AlgorithmCategory, bytes, element);
}

pub fn parseAttribute(bytes: []const u8, element: der.Element) ParseEnumError!Attribute {
    return parseEnum(Attribute, bytes, element);
}

pub fn parseNamedCurve(bytes: []const u8, element: der.Element) ParseEnumError!NamedCurve {
    return parseEnum(NamedCurve, bytes, element);
}

pub fn parseExtensionId(bytes: []const u8, element: der.Element) ParseEnumError!ExtensionId {
    return parseEnum(ExtensionId, bytes, element);
}

fn parseEnum(comptime E: type, bytes: []const u8, element: der.Element) ParseEnumError!E {
    if (element.identifier.tag != .object_identifier) return error.CertificateFieldHasWrongDataType;
    return E.map.get(bytes[element.slice.start..element.slice.end]) orelse error.CertificateHasUnrecognizedObjectId;
}

pub const ParseVersionError = error{ UnsupportedCertificateVersion, CertificateFieldHasInvalidLength };

pub fn parseVersion(bytes: []const u8, version_elem: der.Element) ParseVersionError!Version {
    if (@as(u8, @bitCast(version_elem.identifier)) != 0xa0) return .v1;
    if (version_elem.slice.end - version_elem.slice.start != 3) return error.CertificateFieldHasInvalidLength;
    const encoded_version = bytes[version_elem.slice.start..version_elem.slice.end];
    if (mem.eql(u8, encoded_version, "\x02\x01\x02")) return .v3;
    if (mem.eql(u8, encoded_version, "\x02\x01\x01")) return .v2;
    if (mem.eql(u8, encoded_version, "\x02\x01\x00")) return .v1;
    return error.UnsupportedCertificateVersion;
}

fn verifyEcdsa(algorithm: Algorithm, message: []const u8, encoded_sig: []const u8, pub_key_algo: Parsed.PubKeyAlgo, sec1_pub_key: []const u8) Parsed.VerifyError!void {
    const sig_named_curve = switch (pub_key_algo) {
        .X9_62_id_ecPublicKey => |named_curve| named_curve,
        else => return error.CertificateSignatureAlgorithmMismatch,
    };
    switch (algorithm) {
        .ecdsa_with_SHA256 => {
            if (sig_named_curve != .X9_62_prime256v1) return error.CertificateSignatureNamedCurveUnsupported;
            const sig = EcdsaP256Sha256.Signature.fromDer(encoded_sig) catch return error.CertificateSignatureInvalid;
            const pub_key = EcdsaP256Sha256.PublicKey.fromSec1(sec1_pub_key) catch return error.CertificateSignatureInvalid;
            var verifier = sig.verifier(pub_key) catch return error.CertificateSignatureInvalid;
            verifier.update(message);
            verifier.verify() catch return error.CertificateSignatureInvalid;
        },
        .ecdsa_with_SHA384 => {
            if (sig_named_curve != .secp384r1) return error.CertificateSignatureNamedCurveUnsupported;
            const sig = EcdsaP384Sha384.Signature.fromDer(encoded_sig) catch return error.CertificateSignatureInvalid;
            const pub_key = EcdsaP384Sha384.PublicKey.fromSec1(sec1_pub_key) catch return error.CertificateSignatureInvalid;
            var verifier = sig.verifier(pub_key) catch return error.CertificateSignatureInvalid;
            verifier.update(message);
            verifier.verify() catch return error.CertificateSignatureInvalid;
        },
        else => return error.CertificateSignatureAlgorithmUnsupported,
    }
}

fn verifyRsa(algorithm: Algorithm, msg: []const u8, sig: []const u8, pub_key_algo: Parsed.PubKeyAlgo, pub_key: []const u8) Parsed.VerifyError!void {
    if (pub_key_algo != .rsaEncryption) return error.CertificateSignatureAlgorithmMismatch;
    const components = rsa.PublicKey.parseDer(pub_key) catch return error.CertificatePublicKeyInvalid;
    switch (components.modulus.len) {
        inline 128, 256, 384, 512 => |modulus_len| {
            if (sig.len != modulus_len) return error.CertificateSignatureInvalidLength;
            const key = rsa.PublicKey.fromBytes(components.exponent, components.modulus) catch return error.CertificatePublicKeyInvalid;
            const sig_buf = rsa.PKCS1v1_5Signature.fromBytes(modulus_len, sig);
            switch (algorithm) {
                .sha256WithRSAEncryption => rsa.PKCS1v1_5Signature.concatVerify(modulus_len, sig_buf, &.{msg}, key, Sha256) catch return error.CertificateSignatureInvalid,
                .sha384WithRSAEncryption => rsa.PKCS1v1_5Signature.concatVerify(modulus_len, sig_buf, &.{msg}, key, Sha384) catch return error.CertificateSignatureInvalid,
                .sha512WithRSAEncryption => rsa.PKCS1v1_5Signature.concatVerify(modulus_len, sig_buf, &.{msg}, key, Sha512) catch return error.CertificateSignatureInvalid,
                else => return error.CertificateSignatureAlgorithmUnsupported,
            }
        },
        else => return error.CertificateSignatureUnsupportedBitCount,
    }
}

pub const rsa = struct {
    const max_key_der_len = 544;

    pub const PSSSignature = struct {
        pub const VerifyError = error{InvalidSignature};

        pub fn fromBytes(comptime modulus_len: usize, msg: []const u8) [modulus_len]u8 {
            var result: [modulus_len]u8 = undefined;
            @memcpy(result[0..msg.len], msg);
            @memset(result[msg.len..], 0);
            return result;
        }

        pub fn verify(comptime modulus_len: usize, sig: [modulus_len]u8, msg: []const u8, public_key: PublicKey, comptime Hash: type) VerifyError!void {
            try concatVerify(modulus_len, sig, &.{msg}, public_key, Hash);
        }

        pub fn concatVerify(comptime modulus_len: usize, sig: [modulus_len]u8, msg: []const []const u8, public_key: PublicKey, comptime Hash: type) VerifyError!void {
            try verifyWithPsa(sig[0..], msg, public_key, Hash, true);
        }
    };

    pub const PKCS1v1_5Signature = struct {
        pub const VerifyError = error{InvalidSignature};

        pub fn fromBytes(comptime modulus_len: usize, msg: []const u8) [modulus_len]u8 {
            var result: [modulus_len]u8 = undefined;
            @memcpy(result[0..msg.len], msg);
            @memset(result[msg.len..], 0);
            return result;
        }

        pub fn verify(comptime modulus_len: usize, sig: [modulus_len]u8, msg: []const u8, public_key: PublicKey, comptime Hash: type) VerifyError!void {
            try concatVerify(modulus_len, sig, &.{msg}, public_key, Hash);
        }

        pub fn concatVerify(comptime modulus_len: usize, sig: [modulus_len]u8, msg: []const []const u8, public_key: PublicKey, comptime Hash: type) VerifyError!void {
            try verifyWithPsa(sig[0..], msg, public_key, Hash, false);
        }
    };

    pub const PublicKey = struct {
        der: [max_key_der_len]u8,
        der_len: usize,

        pub const FromBytesError = error{CertificatePublicKeyInvalid};

        pub fn fromBytes(exponent: []const u8, modulus: []const u8) FromBytesError!PublicKey {
            if (modulus.len < 64 or exponent.len == 0 or exponent.len > 4) return error.CertificatePublicKeyInvalid;
            const e_value = std.mem.readVarInt(u32, exponent, .big);
            if (e_value < 3 or (e_value & 1) == 0) return error.CertificatePublicKeyInvalid;

            var out: [max_key_der_len]u8 = undefined;
            const der_len = encodeRsaPublicKeyDer(&out, modulus, exponent) catch return error.CertificatePublicKeyInvalid;
            return .{ .der = out, .der_len = der_len };
        }

        pub const ParseDerError = der.Element.ParseError || error{CertificateFieldHasWrongDataType};

        pub fn parseDer(pub_key: []const u8) ParseDerError!struct { modulus: []const u8, exponent: []const u8 } {
            const pub_key_seq = try der.Element.parse(pub_key, 0);
            if (pub_key_seq.identifier.tag != .sequence) return error.CertificateFieldHasWrongDataType;
            const modulus_elem = try der.Element.parse(pub_key, pub_key_seq.slice.start);
            if (modulus_elem.identifier.tag != .integer) return error.CertificateFieldHasWrongDataType;
            const exponent_elem = try der.Element.parse(pub_key, modulus_elem.slice.end);
            if (exponent_elem.identifier.tag != .integer) return error.CertificateFieldHasWrongDataType;
            const modulus_raw = pub_key[modulus_elem.slice.start..modulus_elem.slice.end];
            const modulus_offset = for (modulus_raw, 0..) |byte, i| {
                if (byte != 0) break i;
            } else modulus_raw.len;
            return .{
                .modulus = modulus_raw[modulus_offset..],
                .exponent = pub_key[exponent_elem.slice.start..exponent_elem.slice.end],
            };
        }
    };

    fn verifyWithPsa(sig: []const u8, msg: []const []const u8, public_key: PublicKey, comptime Hash: type, use_pss: bool) error{InvalidSignature}!void {
        var digest: [Hash.digest_length]u8 = undefined;
        var hasher = Hash.init(.{});
        for (msg) |part| hasher.update(part);
        hasher.final(&digest);

        var attrs = psa_key.KeyAttributes.init();
        defer attrs.deinit();
        const hash_alg = hashAlg(Hash);
        attrs.setType(psa_types.key_type.rsaPublicKey);
        attrs.setUsage(psa_types.usage.verify_hash);
        attrs.setAlgorithm(if (use_pss) psa_types.alg.rsaPss(hash_alg) else psa_types.alg.rsaPkcs1v15Sign(hash_alg));
        shared.psa_mutex.lock();
        defer shared.psa_mutex.unlock();
        var key = psa_key.Key.import(&attrs, public_key.der[0..public_key.der_len]) catch return error.InvalidSignature;
        defer key.deinit();
        key.verifyHash(if (use_pss) psa_types.alg.rsaPss(hash_alg) else psa_types.alg.rsaPkcs1v15Sign(hash_alg), &digest, sig) catch return error.InvalidSignature;
    }

    fn hashAlg(comptime Hash: type) psa_types.Algorithm {
        if (Hash.digest_length == Sha256.digest_length) return psa_types.alg.sha256;
        if (Hash.digest_length == Sha384.digest_length) return psa_types.alg.sha384;
        if (Hash.digest_length == Sha512.digest_length) return psa_types.alg.sha512;
        @compileError("unsupported RSA certificate hash");
    }

    fn encodeRsaPublicKeyDer(out: []u8, modulus: []const u8, exponent: []const u8) !usize {
        const modulus_pad: usize = if (modulus.len > 0 and (modulus[0] & 0x80) != 0) 1 else 0;
        const exponent_pad: usize = if (exponent.len > 0 and (exponent[0] & 0x80) != 0) 1 else 0;
        const mod_body_len = modulus.len + modulus_pad;
        const exp_body_len = exponent.len + exponent_pad;
        const mod_len_len = derLengthSize(mod_body_len);
        const exp_len_len = derLengthSize(exp_body_len);
        const body_len = 1 + mod_len_len + mod_body_len + 1 + exp_len_len + exp_body_len;
        const seq_len_len = derLengthSize(body_len);
        const total_len = 1 + seq_len_len + body_len;
        if (total_len > out.len) return error.CertificatePublicKeyInvalid;

        var i: usize = 0;
        out[i] = 0x30;
        i += 1;
        i += writeDerLength(out[i..], body_len);
        out[i] = 0x02;
        i += 1;
        i += writeDerLength(out[i..], mod_body_len);
        if (modulus_pad == 1) {
            out[i] = 0;
            i += 1;
        }
        @memcpy(out[i..][0..modulus.len], modulus);
        i += modulus.len;
        out[i] = 0x02;
        i += 1;
        i += writeDerLength(out[i..], exp_body_len);
        if (exponent_pad == 1) {
            out[i] = 0;
            i += 1;
        }
        @memcpy(out[i..][0..exponent.len], exponent);
        i += exponent.len;
        return i;
    }

    fn derLengthSize(len: usize) usize {
        if (len < 0x80) return 1;
        if (len <= 0xff) return 2;
        return 3;
    }

    fn writeDerLength(out: []u8, len: usize) usize {
        if (len < 0x80) {
            out[0] = @intCast(len);
            return 1;
        }
        if (len <= 0xff) {
            out[0] = 0x81;
            out[1] = @intCast(len);
            return 2;
        }
        out[0] = 0x82;
        out[1] = @intCast(len >> 8);
        out[2] = @intCast(len & 0xff);
        return 3;
    }
};

pub const der = struct {
    pub const Class = enum(u2) { universal, application, context_specific, private };
    pub const PC = enum(u1) { primitive, constructed };
    pub const Identifier = packed struct(u8) {
        tag: Tag,
        pc: PC,
        class: Class,
    };
    pub const Tag = enum(u5) {
        boolean = 1,
        integer = 2,
        bitstring = 3,
        octetstring = 4,
        null = 5,
        object_identifier = 6,
        sequence = 16,
        sequence_of = 17,
        utc_time = 23,
        generalized_time = 24,
        _,
    };

    pub const Element = struct {
        identifier: Identifier,
        slice: Slice,

        pub const Slice = struct {
            start: u32,
            end: u32,

            pub const empty: Slice = .{ .start = 0, .end = 0 };
        };

        pub const ParseError = error{CertificateFieldHasInvalidLength};

        pub fn parse(bytes: []const u8, index: u32) Element.ParseError!Element {
            var i = index;
            if (i + 2 > bytes.len) return error.CertificateFieldHasInvalidLength;
            const identifier: Identifier = @bitCast(bytes[i]);
            i += 1;
            const size_byte = bytes[i];
            i += 1;
            if ((size_byte >> 7) == 0) {
                const end = i + size_byte;
                if (end > bytes.len) return error.CertificateFieldHasInvalidLength;
                return .{ .identifier = identifier, .slice = .{ .start = i, .end = @intCast(end) } };
            }

            const len_size: u7 = @truncate(size_byte);
            if (len_size == 0 or len_size > @sizeOf(u32) or i + len_size > bytes.len) {
                return error.CertificateFieldHasInvalidLength;
            }
            const end_i = i + len_size;
            var long_form_size: u32 = 0;
            while (i < end_i) : (i += 1) {
                long_form_size = (long_form_size << 8) | bytes[i];
            }
            const end = i + long_form_size;
            if (end > bytes.len) return error.CertificateFieldHasInvalidLength;
            return .{ .identifier = identifier, .slice = .{ .start = i, .end = @intCast(end) } };
        }
    };
};

const MapContext = struct {
    cb: *const Bundle,

    pub fn hash(ctx: MapContext, k: der.Element.Slice) u64 {
        return std.hash_map.hashString(ctx.cb.bytes.items[k.start..k.end]);
    }

    pub fn eql(ctx: MapContext, a: der.Element.Slice, b: der.Element.Slice) bool {
        const bytes = ctx.cb.bytes.items;
        return mem.eql(u8, bytes[a.start..a.end], bytes[b.start..b.end]);
    }
};

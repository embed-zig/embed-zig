//! std runtime — validates all std implementations against runtime contracts.

const std = @import("std");

const std_time = @import("std/time.zig");
const std_log = @import("std/log.zig");
const std_rng = @import("std/rng.zig");
const std_sync = @import("std/sync.zig");
const std_thread = @import("std/thread.zig");
const std_system = @import("std/system.zig");
const std_fs = @import("std/fs.zig");
const std_channel = @import("std/channel.zig");
const std_select = @import("std/select.zig");
const std_socket = @import("std/socket.zig");
const std_netif = @import("std/netif.zig");
const std_ota_backend = @import("std/ota_backend.zig");
const std_crypto_hash = @import("std/crypto/hash.zig");
const std_crypto_hmac = @import("std/crypto/hmac.zig");
const std_crypto_hkdf = @import("std/crypto/hkdf.zig");
const std_crypto_aead = @import("std/crypto/aead.zig");
const std_crypto_pki = @import("std/crypto/pki.zig");
const std_crypto_rsa = @import("std/crypto/rsa.zig");
const std_crypto_kex = @import("std/crypto/kex.zig");
const std_crypto_x509 = @import("std/crypto/x509.zig");

pub const Time = std_time.Time;
pub const Log = std_log.Log;
pub const Rng = std_rng.Rng;
pub const Mutex = std_sync.Mutex;
pub const Condition = std_sync.Condition;
pub const Notify = std_sync.Notify;
pub const Thread = std_thread.Thread;
pub const System = std_system.System;
pub const Fs = std_fs.Fs;
pub const Channel = std_channel.Channel;
pub const Selector = std_select.Selector;
pub const Socket = std_socket.Socket;
pub const NetIf = std_netif.NetIf;
pub const OtaBackend = std_ota_backend.OtaBackend;
pub const Crypto = struct {
    pub const Sha256 = std_crypto_hash.Sha256;
    pub const Sha384 = std_crypto_hash.Sha384;
    pub const Sha512 = std_crypto_hash.Sha512;

    pub const HmacSha256 = std_crypto_hmac.HmacSha256;
    pub const HmacSha384 = std_crypto_hmac.HmacSha384;
    pub const HmacSha512 = std_crypto_hmac.HmacSha512;

    pub const HkdfSha256 = std_crypto_hkdf.HkdfSha256;
    pub const HkdfSha384 = std_crypto_hkdf.HkdfSha384;
    pub const HkdfSha512 = std_crypto_hkdf.HkdfSha512;

    pub const Aes128Gcm = std_crypto_aead.Aes128Gcm;
    pub const Aes256Gcm = std_crypto_aead.Aes256Gcm;
    pub const ChaCha20Poly1305 = std_crypto_aead.ChaCha20Poly1305;

    pub const Ed25519 = std_crypto_pki.Ed25519;
    pub const EcdsaP256Sha256 = std_crypto_pki.EcdsaP256Sha256;
    pub const EcdsaP384Sha384 = std_crypto_pki.EcdsaP384Sha384;

    pub const rsa = std_crypto_rsa.rsa;

    pub const X25519 = std_crypto_kex.X25519;
    pub const P256 = std_crypto_kex.P256;

    pub const Rng = struct {
        pub fn fill(buf: []u8) void {
            std.crypto.random.bytes(buf);
        }
    };

    pub const x509 = std_crypto_x509;
};

pub const test_exports = blk: {
    const __test_export_0 = std_time;
    const __test_export_1 = std_log;
    const __test_export_2 = std_rng;
    const __test_export_3 = std_sync;
    const __test_export_4 = std_thread;
    const __test_export_5 = std_system;
    const __test_export_6 = std_fs;
    const __test_export_7 = std_socket;
    const __test_export_8 = std_netif;
    const __test_export_9 = std_ota_backend;
    const __test_export_10 = std_crypto_hash;
    const __test_export_11 = std_crypto_hmac;
    const __test_export_12 = std_crypto_hkdf;
    const __test_export_13 = std_crypto_aead;
    const __test_export_14 = std_crypto_pki;
    const __test_export_15 = std_crypto_rsa;
    const __test_export_16 = std_crypto_kex;
    const __test_export_17 = std_crypto_x509;
    break :blk struct {
        pub const std_time = __test_export_0;
        pub const std_log = __test_export_1;
        pub const std_rng = __test_export_2;
        pub const std_sync = __test_export_3;
        pub const std_thread = __test_export_4;
        pub const std_system = __test_export_5;
        pub const std_fs = __test_export_6;
        pub const std_socket = __test_export_7;
        pub const std_netif = __test_export_8;
        pub const std_ota_backend = __test_export_9;
        pub const std_crypto_hash = __test_export_10;
        pub const std_crypto_hmac = __test_export_11;
        pub const std_crypto_hkdf = __test_export_12;
        pub const std_crypto_aead = __test_export_13;
        pub const std_crypto_pki = __test_export_14;
        pub const std_crypto_rsa = __test_export_15;
        pub const std_crypto_kex = __test_export_16;
        pub const std_crypto_x509 = __test_export_17;
    };
};

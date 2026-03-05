//! Hash functions - ESP32 mbedTLS implementation.
//!
//! SHA-256/384/512 using mbedTLS. Hardware accelerated on ESP32 where available.

const mbed = @import("esp").mbedtls.mbed_tls;

pub const Sha256 = struct {
    pub const digest_length = 32;
    pub const block_length = 64;

    ctx: mbed.sha256_context,

    pub fn init() Sha256 {
        var self: Sha256 = undefined;
        mbed.sha256_init(&self.ctx);
        _ = mbed.sha256_starts(&self.ctx, 0);
        return self;
    }

    pub fn update(self: *Sha256, data: []const u8) void {
        _ = mbed.sha256_update(&self.ctx, data.ptr, data.len);
    }

    pub fn final(self: *Sha256) [digest_length]u8 {
        var out: [digest_length]u8 = undefined;
        _ = mbed.sha256_finish(&self.ctx, &out);
        mbed.sha256_free(&self.ctx);
        return out;
    }

    pub fn hash(data: []const u8, out: *[digest_length]u8) void {
        _ = mbed.sha256_hash(data.ptr, data.len, out, 0);
    }
};

pub const Sha384 = struct {
    pub const digest_length = 48;
    pub const block_length = 128;

    ctx: mbed.sha512_context,

    pub fn init() Sha384 {
        var self: Sha384 = undefined;
        mbed.sha512_init(&self.ctx);
        _ = mbed.sha512_starts(&self.ctx, 1);
        return self;
    }

    pub fn update(self: *Sha384, data: []const u8) void {
        _ = mbed.sha512_update(&self.ctx, data.ptr, data.len);
    }

    pub fn final(self: *Sha384) [digest_length]u8 {
        var out: [64]u8 = undefined;
        _ = mbed.sha512_finish(&self.ctx, &out);
        mbed.sha512_free(&self.ctx);
        return out[0..digest_length].*;
    }

    pub fn hash(data: []const u8, out: *[digest_length]u8) void {
        var full_out: [64]u8 = undefined;
        _ = mbed.sha512_hash(data.ptr, data.len, &full_out, 1);
        out.* = full_out[0..digest_length].*;
    }
};

pub const Sha512 = struct {
    pub const digest_length = 64;
    pub const block_length = 128;

    ctx: mbed.sha512_context,

    pub fn init() Sha512 {
        var self: Sha512 = undefined;
        mbed.sha512_init(&self.ctx);
        _ = mbed.sha512_starts(&self.ctx, 0);
        return self;
    }

    pub fn update(self: *Sha512, data: []const u8) void {
        _ = mbed.sha512_update(&self.ctx, data.ptr, data.len);
    }

    pub fn final(self: *Sha512) [digest_length]u8 {
        var out: [digest_length]u8 = undefined;
        _ = mbed.sha512_finish(&self.ctx, &out);
        mbed.sha512_free(&self.ctx);
        return out;
    }

    pub fn hash(data: []const u8, out: *[digest_length]u8) void {
        _ = mbed.sha512_hash(data.ptr, data.len, out, 0);
    }
};

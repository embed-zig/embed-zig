const shared = @import("../shared.zig");

const c = shared.c;
const checkMbed = shared.checkMbed;

pub const has_hardware_support = false;
pub const Aes128 = AesBlockCipher(16, 128);
pub const Aes256 = AesBlockCipher(32, 256);

const Block = [16]u8;

fn AesBlockCipher(comptime key_len: usize, comptime bits: usize) type {
    return struct {
        pub const key_bits = bits;
        pub const block = Block;
        pub const EncryptCtx = AesEncryptCtx(key_len);
        pub const DecryptCtx = AesDecryptCtx(key_len);

        pub fn initEnc(key: [key_bits / 8]u8) EncryptCtx {
            return EncryptCtx.init(key);
        }

        pub fn initDec(key: [key_bits / 8]u8) DecryptCtx {
            return DecryptCtx.init(key);
        }
    };
}

fn AesEncryptCtx(comptime key_len: usize) type {
    return struct {
        ctx: c.mbedtls_aes_context,

        const Self = @This();

        pub fn init(key: [key_len]u8) Self {
            var self: Self = undefined;
            c.mbedtls_aes_init(&self.ctx);
            checkMbed(c.mbedtls_aes_setkey_enc(&self.ctx, &key, key_len * 8));
            return self;
        }

        pub fn encrypt(self: Self, out: *[16]u8, input: *const [16]u8) void {
            var ctx = self.ctx;
            defer c.mbedtls_aes_free(&ctx);
            checkMbed(c.mbedtls_aes_crypt_ecb(&ctx, c.MBEDTLS_AES_ENCRYPT, input, out));
        }
    };
}

fn AesDecryptCtx(comptime key_len: usize) type {
    return struct {
        ctx: c.mbedtls_aes_context,

        const Self = @This();

        pub fn init(key: [key_len]u8) Self {
            var self: Self = undefined;
            c.mbedtls_aes_init(&self.ctx);
            checkMbed(c.mbedtls_aes_setkey_dec(&self.ctx, &key, key_len * 8));
            return self;
        }

        pub fn decrypt(self: Self, out: *[16]u8, input: *const [16]u8) void {
            var ctx = self.ctx;
            defer c.mbedtls_aes_free(&ctx);
            checkMbed(c.mbedtls_aes_crypt_ecb(&ctx, c.MBEDTLS_AES_DECRYPT, input, out));
        }
    };
}

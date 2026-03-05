//! HMAC functions - ESP32 mbedTLS implementation.
//!
//! HMAC-SHA256/384/512 using mbedTLS message-digest API.

const mbed = @import("esp").mbedtls.mbed_tls;

pub const HmacSha256 = HmacWrapper(mbed.MD_SHA256, 32, 64);
pub const HmacSha384 = HmacWrapper(mbed.MD_SHA384, 48, 128);
pub const HmacSha512 = HmacWrapper(mbed.MD_SHA512, 64, 128);

fn HmacWrapper(comptime md_type: c_int, comptime mac_len: usize, comptime blk_len: usize) type {
    return struct {
        pub const mac_length = mac_len;
        pub const block_length = blk_len;

        ctx: mbed.md_context_t,

        pub fn create(out: *[mac_length]u8, data: []const u8, key: []const u8) void {
            _ = mbed.md_hmac(
                mbed.md_info_from_type(md_type),
                key.ptr,
                key.len,
                data.ptr,
                data.len,
                out,
            );
        }

        pub fn init(key: []const u8) @This() {
            var self: @This() = undefined;
            mbed.md_init(&self.ctx);
            _ = mbed.md_setup(&self.ctx, mbed.md_info_from_type(md_type), 1);
            _ = mbed.md_hmac_starts(&self.ctx, key.ptr, key.len);
            return self;
        }

        pub fn update(self: *@This(), data: []const u8) void {
            _ = mbed.md_hmac_update(&self.ctx, data.ptr, data.len);
        }

        pub fn final(self: *@This()) [mac_length]u8 {
            var out: [mac_length]u8 = undefined;
            _ = mbed.md_hmac_finish(&self.ctx, &out);
            mbed.md_free(&self.ctx);
            return out;
        }
    };
}

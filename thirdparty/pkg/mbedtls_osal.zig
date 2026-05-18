//! mbedtls_osal - Mbed TLS platform hooks backed by a glib runtime.
//!
//! Usage:
//!   const mbedtls_osal = @import("mbedtls_osal");
//!   const Exports = mbedtls_osal.make(grt);
//!   comptime {
//!       _ = Exports.mbedtls_ms_time;
//!       _ = Exports.mbedtls_psa_external_get_random;
//!   }

const glib = @import("glib");

const c = @cImport({
    @cInclude("psa/crypto.h");
    @cInclude("mbedtls/platform_time.h");
    @cInclude("psa/crypto_extra.h");
});

pub fn make(comptime grt: type) type {
    comptime {
        if (!glib.runtime.is(grt)) @compileError("mbedtls_osal.make requires a glib runtime namespace");
    }

    return struct {
        pub export fn mbedtls_ms_time() c.mbedtls_ms_time_t {
            const now_ms = grt.time.now().unixMilli();
            if (now_ms <= 0) return 0;
            return @intCast(now_ms);
        }

        pub export fn mbedtls_psa_external_get_random(
            context: ?*c.mbedtls_psa_external_random_context_t,
            output: [*c]u8,
            output_size: usize,
            output_length: ?*usize,
        ) c.psa_status_t {
            _ = context;

            const out_len = output_length orelse return c.PSA_ERROR_INVALID_ARGUMENT;
            out_len.* = 0;
            if (output_size == 0) return c.PSA_SUCCESS;
            if (output == null) return c.PSA_ERROR_INVALID_ARGUMENT;

            const out = output[0..output_size];
            grt.std.crypto.random.bytes(out);
            out_len.* = output_size;
            return c.PSA_SUCCESS;
        }
    };
}

const glib = @import("glib");
const mbedtls_osal = @import("mbedtls_osal");
const ChannelType = @import("src/sync/Channel.zig");
const net_backend = @import("src/net.zig");
const stdz_backend = @import("src/stdz.zig");
const time_backend = @import("src/time.zig");

pub const runtime = glib.runtime.make(.{
    .stdz_impl = stdz_backend,
    .time_impl = time_backend.impl,
    .channel_factory = ChannelType.ChannelFactory,
    .net_impl = net_backend.impl,
});

const mbedtls_exports = mbedtls_osal.make(runtime);
comptime {
    _ = mbedtls_exports.mbedtls_ms_time;
    _ = mbedtls_exports.mbedtls_psa_external_get_random;
}

pub const test_support = struct {
    pub const net = net_backend.posix_impl;
};

const glib = @import("glib");
const mbedtls_osal = @import("mbedtls_osal");
const compress_backend = @import("src/compress.zig");
const fs_backend = @import("src/fs.zig");
const net_backend = @import("src/net.zig");
const stdz_backend = @import("src/stdz.zig");
const sync_backend = @import("src/sync.zig");
const system_backend = @import("src/system.zig");
const task_backend = @import("src/task.zig");
const time_backend = @import("src/time.zig");

pub const fs = fs_backend;
pub const compress = compress_backend;
pub const sync = sync_backend;
pub const system = system_backend;

pub const runtime = glib.runtime.make(.{
    .stdz_impl = stdz_backend,
    .time_impl = time_backend.impl,
    .system_impl = system_backend.impl,
    .sync_impl = sync_backend.impl,
    .channel_factory = sync_backend.ChannelFactory,
    .net_impl = net_backend.impl,
    .fs_impl = fs_backend.impl,
    .task_impl = task_backend.impl,
    .compress_impl = compress_backend.impl,
});

const mbedtls_exports = mbedtls_osal.make(runtime);
comptime {
    _ = mbedtls_exports.mbedtls_ms_time;
    _ = mbedtls_exports.mbedtls_psa_external_get_random;
}

pub const test_support = struct {
    pub const net = net_backend.posix_impl;
    pub const fs = fs_backend.impl;
    pub const compress = compress_backend.impl;
};

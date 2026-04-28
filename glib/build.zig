const std = @import("std");

const lib_stdz = @import("build/lib/stdz.zig");
const lib_testing = @import("build/lib/testing.zig");
const lib_context = @import("build/lib/context.zig");
const lib_time = @import("build/lib/time.zig");
const lib_sync = @import("build/lib/sync.zig");
const lib_io = @import("build/lib/io.zig");
const lib_mime = @import("build/lib/mime.zig");
const lib_net = @import("build/lib/net.zig");
const lib_crypto = @import("build/lib/crypto.zig");
const lib_glib = @import("build/lib/glib.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const stdz_mod = lib_stdz.create(b, target, optimize);
    const testing_mod = lib_testing.create(b, target, optimize);
    const context_mod = lib_context.create(b, target, optimize);
    const time_mod = lib_time.create(b, target, optimize);
    const sync_mod = lib_sync.create(b, target, optimize);
    const io_mod = lib_io.create(b, target, optimize);
    const mime_mod = lib_mime.create(b, target, optimize);
    const net_mod = lib_net.create(b, target, optimize);
    const crypto_mod = lib_crypto.create(b, target, optimize);

    lib_stdz.link(stdz_mod);
    lib_context.link(context_mod, .{
        .stdz = stdz_mod,
    });
    lib_testing.link(testing_mod, .{
        .context = context_mod,
        .stdz = stdz_mod,
    });
    lib_time.link(time_mod, .{
        .testing = testing_mod,
    });
    lib_sync.link(sync_mod, .{
        .context = context_mod,
        .stdz = stdz_mod,
        .testing = testing_mod,
    });
    lib_io.link(io_mod, .{
        .stdz = stdz_mod,
        .testing = testing_mod,
    });
    lib_mime.link(mime_mod, .{
        .stdz = stdz_mod,
        .testing = testing_mod,
    });
    lib_net.link(net_mod, .{
        .stdz = stdz_mod,
        .sync = sync_mod,
        .context = context_mod,
        .io = io_mod,
        .testing = testing_mod,
    });
    lib_crypto.link(crypto_mod, .{
        .testing = testing_mod,
    });
    b.modules.put("stdz", stdz_mod) catch @panic("OOM");
    b.modules.put("testing", testing_mod) catch @panic("OOM");
    b.modules.put("context", context_mod) catch @panic("OOM");
    b.modules.put("time", time_mod) catch @panic("OOM");
    b.modules.put("sync", sync_mod) catch @panic("OOM");
    b.modules.put("io", io_mod) catch @panic("OOM");
    b.modules.put("mime", mime_mod) catch @panic("OOM");
    b.modules.put("net", net_mod) catch @panic("OOM");
    b.modules.put("crypto", crypto_mod) catch @panic("OOM");

    const glib_mod = lib_glib.create(b, target, optimize);
    lib_glib.link(glib_mod, .{
        .stdz = stdz_mod,
        .testing = testing_mod,
        .context = context_mod,
        .time = time_mod,
        .sync = sync_mod,
        .io = io_mod,
        .mime = mime_mod,
        .net = net_mod,
        .crypto = crypto_mod,
    });
    b.modules.put("glib", glib_mod) catch @panic("OOM");
}

pub const modules = .{
    @import("embed_audio.zig"),
    @import("embed_bt.zig"),
    @import("embed_drivers.zig"),
    @import("embed_ledstrip.zig"),
    @import("embed_motion.zig"),
    @import("embed_zux.zig"),

    @import("glib_context.zig"),
    @import("glib_crypto.zig"),
    @import("glib_io.zig"),
    @import("glib_mime.zig"),
    @import("glib_net.zig"),
    @import("glib_runtime.zig"),
    @import("glib_stdz.zig"),
    @import("glib_sync.zig"),
    @import("glib_testing.zig"),
    @import("glib_time.zig"),

    @import("thirdparty_core_bluetooth.zig"),
    @import("thirdparty_core_wlan.zig"),
    @import("thirdparty_lvgl.zig"),
    @import("thirdparty_mbedtls.zig"),
    @import("thirdparty_opus.zig"),
    @import("thirdparty_portaudio.zig"),
    @import("thirdparty_speexdsp.zig"),
    @import("thirdparty_stb_truetype.zig"),
};

comptime {
    for (modules) |module| {
        _ = module;
    }
}

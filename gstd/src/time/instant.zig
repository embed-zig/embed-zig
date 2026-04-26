//! Host-backed instant implementation selection.

const builtin = @import("builtin");

pub const posix_impl: type = @import("instant/posix.zig");

pub const impl: type = switch (builtin.target.os.tag) {
    .macos, .ios, .watchos, .tvos, .visionos => @import("instant/darwin.zig"),
    .freebsd, .dragonfly => @import("instant/bsd.zig"),
    .linux => @import("instant/linux.zig"),
    .windows => @import("instant/windows.zig"),
    .wasi => @import("instant/wasi.zig"),
    .uefi => @import("instant/uefi.zig"),
    else => posix_impl,
};

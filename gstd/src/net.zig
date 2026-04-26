const builtin = @import("builtin");

pub const posix_impl: type = if (builtin.target.os.tag == .windows)
    void
else
    @import("net/posix.zig");

pub const impl: type = switch (builtin.target.os.tag) {
    .macos, .ios, .watchos, .tvos => @import("net/darwin.zig"),
    .linux => @import("net/linux.zig"),
    .windows => @import("net/windows.zig"),
    else => posix_impl,
};

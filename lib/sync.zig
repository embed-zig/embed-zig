//! sync — thread coordination primitives.
//!
//! Usage:
//!   const U32Racer = @import("sync").Racer(lib, u32);
//!
//!   var racer = try U32Racer.init(allocator);
//!   defer racer.deinit();
//!
//!   try racer.spawn(.{}, taskFn, .{});
//!   switch (racer.race()) {
//!       .winner => |value| _ = value,
//!       .exhausted => {},
//!   }

const racer_mod = @import("sync/Racer.zig");

pub fn Racer(comptime lib: type, comptime T: type) type {
    return racer_mod.Racer(lib, T);
}

pub const test_runner = struct {
    pub const racer = @import("sync/test_runner/racer.zig");
};

test {
    _ = @import("sync/Racer.zig");
    _ = @import("sync/test_runner/racer.zig");
}

//! std runtime — Runtime backed by Zig standard library.
//!
//! const std_rt = @import("runtime/std.zig");
//! var rt = try std_rt.init(allocator);
//! defer rt.deinit();

const std = @import("std");
const runtime = @import("runtime.zig");
const root = @import("std/root.zig");

pub const Runtime = runtime.Runtime(root.StdRuntimeDecl);

pub fn init(allocator: std.mem.Allocator) anyerror!Runtime {
    return Runtime.init(allocator);
}

test {
    _ = @import("std/tests.zig");
}

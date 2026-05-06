//! opus_osal — libopus platform hooks.
//!
//! Usage:
//!   const opus_osal = @import("opus_osal");
//!   const Exports = opus_osal.make(grt, allocator);
//!   comptime { _ = Exports.opus_alloc_scratch; }

const glib = @import("glib");

pub fn make(comptime grt: type, comptime allocator: glib.std.mem.Allocator) type {
    comptime {
        if (!glib.runtime.is(grt)) @compileError("opus_osal.make requires a glib runtime namespace");
    }

    return struct {
        var scratch: ?[]align(16) u8 = null;

        pub export fn opus_alloc_scratch(size: usize) ?*anyopaque {
            if (scratch) |memory| {
                if (size <= memory.len) return memory.ptr;
                @panic("opus scratch request exceeds allocated scratch");
            }

            const memory = allocator.alignedAlloc(u8, .@"16", size) catch
                @panic("opus scratch allocation failed");
            scratch = memory;
            return memory.ptr;
        }
    };
}

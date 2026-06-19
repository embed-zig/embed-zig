//! compress — runtime-bound portable compression namespace.

const builtin_std = @import("std");

pub const Container = enum {
    raw,
    zlib,
    gzip,
};

pub const InflateError = error{
    InvalidData,
    TruncatedInput,
    OutputTooSmall,
    Unsupported,
    Unexpected,
};

pub const InflateAllocError = InflateError || builtin_std.mem.Allocator.Error || error{
    SizeMismatch,
};

pub const unsupported_impl = struct {
    pub const supports_stream = false;

    pub fn inflate(container: Container, compressed: []const u8, out: []u8) InflateError!usize {
        _ = container;
        _ = compressed;
        _ = out;
        return error.Unsupported;
    }
};

pub fn make(comptime std: type, comptime impl: type) type {
    comptime validateImpl(impl);
    const root = @import("compress.zig");

    return struct {
        pub const Container = root.Container;
        pub const InflateError = root.InflateError;
        pub const InflateAllocError = root.InflateAllocError;
        pub const supports_stream = @hasDecl(impl, "inflateStream");

        pub fn inflate(container: root.Container, compressed: []const u8, out: []u8) root.InflateError!usize {
            return impl.inflate(container, compressed, out);
        }

        pub fn inflateStream(container: root.Container, compressed: []const u8, sink: anytype) !usize {
            if (comptime !supports_stream) @compileError("compress impl does not support inflateStream");
            return impl.inflateStream(container, compressed, sink);
        }

        pub fn inflateAlloc(allocator: std.mem.Allocator, container: root.Container, compressed: []const u8, raw_len: usize) root.InflateAllocError![]u8 {
            const out = try allocator.alloc(u8, raw_len);
            errdefer allocator.free(out);

            const len = try inflate(container, compressed, out);
            if (len != raw_len) return error.SizeMismatch;
            return out;
        }
    };
}

fn validateImpl(comptime impl: type) void {
    const expected = struct {
        fn inflate(_: Container, _: []const u8, _: []u8) InflateError!usize {
            unreachable;
        }
    };

    if (!@hasDecl(impl, "inflate") or @TypeOf(impl.inflate) != @TypeOf(expected.inflate))
        @compileError("compress impl must expose inflate(Container, []const u8, []u8) InflateError!usize");
}

pub const test_runner = struct {
    pub const unit = @import("compress/test_runner/unit.zig");
};

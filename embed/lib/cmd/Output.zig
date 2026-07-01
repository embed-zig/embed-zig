const Output = @This();

ctx: ?*anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    write: *const fn (ctx: ?*anyopaque, bytes: []const u8) anyerror!usize,
    flush: ?*const fn (ctx: ?*anyopaque) anyerror!void = null,
};

pub fn write(self: Output, bytes: []const u8) !usize {
    return self.vtable.write(self.ctx, bytes);
}

pub fn writeAll(self: Output, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = try self.write(bytes[offset..]);
        if (n == 0) return error.WriteZero;
        offset += n;
    }
}

pub fn flush(self: Output) !void {
    if (self.vtable.flush) |flush_fn| try flush_fn(self.ctx);
}

pub fn make(comptime Impl: type) type {
    return struct {
        pub fn init(impl: *Impl) Output {
            return .{
                .ctx = impl,
                .vtable = &.{
                    .write = vtableWrite,
                    .flush = if (@hasDecl(Impl, "flush")) vtableFlush else null,
                },
            };
        }

        fn vtableWrite(ctx: ?*anyopaque, bytes: []const u8) anyerror!usize {
            const impl: *Impl = @ptrCast(@alignCast(ctx.?));
            return impl.write(bytes);
        }

        fn vtableFlush(ctx: ?*anyopaque) anyerror!void {
            const impl: *Impl = @ptrCast(@alignCast(ctx.?));
            return impl.flush();
        }
    };
}

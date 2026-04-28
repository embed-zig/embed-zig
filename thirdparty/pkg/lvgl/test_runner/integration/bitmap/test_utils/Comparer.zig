const display_error = @import("Error.zig");
const DrawArgs = @import("DrawArgs.zig");

ctx: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    check_fn: *const fn (ctx: *anyopaque, draw: DrawArgs) display_error.Error!bool,
};

pub fn init(ctx: *anyopaque, cmp_vtable: *const VTable) @This() {
    return .{
        .ctx = ctx,
        .vtable = cmp_vtable,
    };
}

pub fn from(comptime T: type, self: *T) @This() {
    const Adapter = struct {
        fn checkFn(ctx: *anyopaque, draw: DrawArgs) display_error.Error!bool {
            const typed_self: *T = @ptrCast(@alignCast(ctx));
            return T.check(typed_self, draw);
        }

        const vtable = VTable{
            .check_fn = checkFn,
        };
    };

    return init(self, &Adapter.vtable);
}

pub fn check(self: *const @This(), draw: DrawArgs) display_error.Error!bool {
    return self.vtable.check_fn(self.ctx, draw);
}

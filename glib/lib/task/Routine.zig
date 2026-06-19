const Routine = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    run: *const fn (*anyopaque) void,
};

pub fn init(ctx: anytype, comptime run_fn: anytype) Routine {
    const Ptr = @TypeOf(ctx);
    const info = @typeInfo(Ptr);
    if (info != .pointer) {
        @compileError("task.Routine.init ctx must be a pointer");
    }
    if (info.pointer.is_const) {
        @compileError("task.Routine.init ctx must be a mutable pointer");
    }

    return .{
        .ptr = @ptrCast(ctx),
        .vtable = &struct {
            const vtable: VTable = .{ .run = call };

            fn call(ptr: *anyopaque) void {
                const typed: Ptr = @ptrCast(@alignCast(ptr));
                run_fn(typed);
            }
        }.vtable,
    };
}

pub fn run(self: Routine) void {
    self.vtable.run(self.ptr);
}

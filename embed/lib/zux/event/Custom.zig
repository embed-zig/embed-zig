const Custom = @This();

pub const kind = .custom;

pub const VTable = struct {
    type_id: *const anyopaque,
    type_name: []const u8,
    deinit: *const fn (ptr: *anyopaque) void,
};

source_id: u32,
register_id: u32,
ptr: *anyopaque,
vtable: *const VTable,

pub fn initRegistered(register_id: u32, source_id: u32, pointer: anytype) Custom {
    const Ptr = @TypeOf(pointer);
    const info = @typeInfo(Ptr);
    if (info != .pointer or info.pointer.size != .one)
        @compileError("zux.event.Custom.initRegistered expects a single-item pointer");

    const T = info.pointer.child;
    comptime {
        _ = @as(*const fn (*T) void, &T.deinit);
    }

    return .{
        .source_id = source_id,
        .register_id = register_id,
        .ptr = @ptrCast(pointer),
        .vtable = vtableFor(T),
    };
}

pub fn deinit(self: Custom) void {
    self.vtable.deinit(self.ptr);
}

pub fn is(self: Custom, comptime T: type) bool {
    return self.vtable.type_id == typeId(T);
}

pub fn as(self: Custom, comptime T: type) error{TypeMismatch}!*T {
    if (!self.is(T)) return error.TypeMismatch;
    return @ptrCast(@alignCast(self.ptr));
}

fn TypeIdHolder(comptime T: type) type {
    return struct {
        comptime _phantom: type = T,
        var id: u8 = 0;
    };
}

fn typeId(comptime T: type) *const anyopaque {
    return @ptrCast(&TypeIdHolder(T).id);
}

fn vtableFor(comptime T: type) *const VTable {
    return &struct {
        fn deinitFn(ptr: *anyopaque) void {
            const self: *T = @ptrCast(@alignCast(ptr));
            self.deinit();
        }

        const vtable = VTable{
            .type_id = typeId(T),
            .type_name = @typeName(T),
            .deinit = deinitFn,
        };
    }.vtable;
}

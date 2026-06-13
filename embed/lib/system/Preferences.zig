//! Byte-oriented persistent preferences contract.

pub const OpenOptions = struct {
    create: bool = true,
    read_only: bool = false,
};

pub const OpenError = error{
    InvalidNamespace,
    NotFound,
    PermissionDenied,
    OutOfMemory,
    Unsupported,
    Unexpected,
};

pub const GetError = error{
    InvalidKey,
    NotFound,
    BufferTooSmall,
    PermissionDenied,
    Unexpected,
};

pub const PutError = error{
    InvalidKey,
    ValueTooLarge,
    NoSpaceLeft,
    PermissionDenied,
    Unexpected,
};

pub const RemoveError = error{
    InvalidKey,
    NotFound,
    PermissionDenied,
    Unexpected,
};

pub const ClearError = error{
    PermissionDenied,
    Unexpected,
};

pub const SyncError = error{
    Unsupported,
    Unexpected,
};

pub const Provider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        open: *const fn (ptr: *anyopaque, namespace: []const u8, options: OpenOptions) OpenError!Store,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn init(pointer: anytype) Provider {
        const Ptr = @TypeOf(pointer);
        const info = @typeInfo(Ptr);
        if (info != .pointer or info.pointer.size != .one)
            @compileError("system.Preferences.Provider.init expects a single-item pointer");

        const Impl = info.pointer.child;

        const gen = struct {
            fn openFn(ptr: *anyopaque, namespace: []const u8, options: OpenOptions) OpenError!Store {
                const self: *Impl = @ptrCast(@alignCast(ptr));
                return self.open(namespace, options);
            }

            fn deinitFn(ptr: *anyopaque) void {
                const self: *Impl = @ptrCast(@alignCast(ptr));
                if (@hasDecl(Impl, "deinit")) self.deinit();
            }

            const vtable = VTable{
                .open = openFn,
                .deinit = deinitFn,
            };
        };

        return .{
            .ptr = pointer,
            .vtable = &gen.vtable,
        };
    }

    pub fn open(self: Provider, namespace: []const u8, options: OpenOptions) OpenError!Store {
        return self.vtable.open(self.ptr, namespace, options);
    }

    pub fn deinit(self: Provider) void {
        self.vtable.deinit(self.ptr);
    }
};

pub const Store = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        get: *const fn (ptr: *anyopaque, key: []const u8, out: []u8) GetError!usize,
        put: *const fn (ptr: *anyopaque, key: []const u8, value: []const u8) PutError!void,
        remove: *const fn (ptr: *anyopaque, key: []const u8) RemoveError!void,
        contains: *const fn (ptr: *anyopaque, key: []const u8) bool,
        clear: *const fn (ptr: *anyopaque) ClearError!void,
        sync: *const fn (ptr: *anyopaque) SyncError!void,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn init(pointer: anytype) Store {
        const Ptr = @TypeOf(pointer);
        const info = @typeInfo(Ptr);
        if (info != .pointer or info.pointer.size != .one)
            @compileError("system.Preferences.Store.init expects a single-item pointer");

        const Impl = info.pointer.child;

        const gen = struct {
            fn getFn(ptr: *anyopaque, key: []const u8, out: []u8) GetError!usize {
                const self: *Impl = @ptrCast(@alignCast(ptr));
                return self.get(key, out);
            }

            fn putFn(ptr: *anyopaque, key: []const u8, value: []const u8) PutError!void {
                const self: *Impl = @ptrCast(@alignCast(ptr));
                return self.put(key, value);
            }

            fn removeFn(ptr: *anyopaque, key: []const u8) RemoveError!void {
                const self: *Impl = @ptrCast(@alignCast(ptr));
                return self.remove(key);
            }

            fn containsFn(ptr: *anyopaque, key: []const u8) bool {
                const self: *Impl = @ptrCast(@alignCast(ptr));
                return self.contains(key);
            }

            fn clearFn(ptr: *anyopaque) ClearError!void {
                const self: *Impl = @ptrCast(@alignCast(ptr));
                return self.clear();
            }

            fn syncFn(ptr: *anyopaque) SyncError!void {
                const self: *Impl = @ptrCast(@alignCast(ptr));
                if (@hasDecl(Impl, "sync")) return self.sync();
            }

            fn deinitFn(ptr: *anyopaque) void {
                const self: *Impl = @ptrCast(@alignCast(ptr));
                if (@hasDecl(Impl, "deinit")) self.deinit();
            }

            const vtable = VTable{
                .get = getFn,
                .put = putFn,
                .remove = removeFn,
                .contains = containsFn,
                .clear = clearFn,
                .sync = syncFn,
                .deinit = deinitFn,
            };
        };

        return .{
            .ptr = pointer,
            .vtable = &gen.vtable,
        };
    }

    pub fn get(self: Store, key: []const u8, out: []u8) GetError!usize {
        return self.vtable.get(self.ptr, key, out);
    }

    pub fn put(self: Store, key: []const u8, value: []const u8) PutError!void {
        return self.vtable.put(self.ptr, key, value);
    }

    pub fn remove(self: Store, key: []const u8) RemoveError!void {
        return self.vtable.remove(self.ptr, key);
    }

    pub fn contains(self: Store, key: []const u8) bool {
        return self.vtable.contains(self.ptr, key);
    }

    pub fn clear(self: Store) ClearError!void {
        return self.vtable.clear(self.ptr);
    }

    pub fn sync(self: Store) SyncError!void {
        return self.vtable.sync(self.ptr);
    }

    pub fn deinit(self: Store) void {
        self.vtable.deinit(self.ptr);
    }
};

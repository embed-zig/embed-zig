//! Byte-oriented persistent preferences contract.

const glib = @import("glib");

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

pub const GetAllocError = GetError || error{
    OutOfMemory,
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

pub const ListError = error{
    Unsupported,
    PermissionDenied,
    OutOfMemory,
    Unexpected,
};

pub const EntryType = enum(u8) {
    unknown,
    blob,
    string,
    u8,
    i8,
    u16,
    i16,
    u32,
    i32,
    u64,
    i64,
};

pub const Namespace = struct {
    name_buf: [16]u8 = [_]u8{0} ** 16,
    name_len: u8 = 0,

    pub fn name(self: *const Namespace) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

pub const Entry = struct {
    namespace_buf: [16]u8 = [_]u8{0} ** 16,
    namespace_len: u8 = 0,
    key_buf: [16]u8 = [_]u8{0} ** 16,
    key_len: u8 = 0,
    value_type: EntryType = .unknown,
    value_len: usize = 0,

    pub fn namespace(self: *const Entry) []const u8 {
        return self.namespace_buf[0..self.namespace_len];
    }

    pub fn key(self: *const Entry) []const u8 {
        return self.key_buf[0..self.key_len];
    }
};

pub const Provider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        open: *const fn (ptr: *anyopaque, namespace: []const u8, options: OpenOptions) OpenError!Store,
        list: *const fn (ptr: *anyopaque, allocator: glib.std.mem.Allocator) ListError![]Namespace,
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

            fn unsupportedListFn(_: *anyopaque, _: glib.std.mem.Allocator) ListError![]Namespace {
                return error.Unsupported;
            }

            fn listFn(ptr: *anyopaque, allocator: glib.std.mem.Allocator) ListError![]Namespace {
                if (@hasDecl(Impl, "list")) {
                    const self: *Impl = @ptrCast(@alignCast(ptr));
                    return self.list(allocator);
                } else {
                    return unsupportedListFn(ptr, allocator);
                }
            }

            fn deinitFn(ptr: *anyopaque) void {
                const self: *Impl = @ptrCast(@alignCast(ptr));
                if (@hasDecl(Impl, "deinit")) self.deinit();
            }

            const vtable = VTable{
                .open = openFn,
                .list = listFn,
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

    pub fn list(self: Provider, allocator: glib.std.mem.Allocator) ListError![]Namespace {
        return self.vtable.list(self.ptr, allocator);
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
        get_alloc: *const fn (ptr: *anyopaque, allocator: glib.std.mem.Allocator, key: []const u8) GetAllocError![]u8,
        put: *const fn (ptr: *anyopaque, key: []const u8, value: []const u8) PutError!void,
        remove: *const fn (ptr: *anyopaque, key: []const u8) RemoveError!void,
        contains: *const fn (ptr: *anyopaque, key: []const u8) bool,
        list: *const fn (ptr: *anyopaque, allocator: glib.std.mem.Allocator) ListError![]Entry,
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

            fn getAllocFn(ptr: *anyopaque, allocator: glib.std.mem.Allocator, key: []const u8) GetAllocError![]u8 {
                const self: *Impl = @ptrCast(@alignCast(ptr));
                if (@hasDecl(Impl, "getAlloc")) return self.getAlloc(allocator, key);

                var capacity: usize = 64;
                while (true) {
                    const buffer = allocator.alloc(u8, capacity) catch return error.OutOfMemory;
                    const len = self.get(key, buffer) catch |err| {
                        allocator.free(buffer);
                        if (err == error.BufferTooSmall) {
                            if (capacity > glib.std.math.maxInt(usize) / 2) return error.OutOfMemory;
                            capacity *= 2;
                            continue;
                        }
                        return err;
                    };
                    const result = allocator.alloc(u8, len) catch {
                        allocator.free(buffer);
                        return error.OutOfMemory;
                    };
                    @memcpy(result, buffer[0..len]);
                    allocator.free(buffer);
                    return result;
                }
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

            fn unsupportedListFn(_: *anyopaque, _: glib.std.mem.Allocator) ListError![]Entry {
                return error.Unsupported;
            }

            fn listFn(ptr: *anyopaque, allocator: glib.std.mem.Allocator) ListError![]Entry {
                if (@hasDecl(Impl, "list")) {
                    const self: *Impl = @ptrCast(@alignCast(ptr));
                    return self.list(allocator);
                } else {
                    return unsupportedListFn(ptr, allocator);
                }
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
                .get_alloc = getAllocFn,
                .put = putFn,
                .remove = removeFn,
                .contains = containsFn,
                .list = listFn,
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

    pub fn getAlloc(self: Store, allocator: glib.std.mem.Allocator, key: []const u8) GetAllocError![]u8 {
        return self.vtable.get_alloc(self.ptr, allocator, key);
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

    pub fn list(self: Store, allocator: glib.std.mem.Allocator) ListError![]Entry {
        return self.vtable.list(self.ptr, allocator);
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

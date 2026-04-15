//! Pool coordination primitive — thread-safe reusable object storage.
//!
//! `Pool.init(&impl)` erases a concrete pool implementation behind a small
//! vtable. `Pool.make(lib, T)` builds a mutex-protected pool of `T` values.
//! Callers can either fetch typed pointers with `getTyped()` / `putTyped()` or
//! use the erased wrapper when type information is managed externally.

const embed = @import("embed");
const testing_api = @import("testing");

const Pool = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    get: *const fn (ptr: *anyopaque) ?*anyopaque,
    put: *const fn (ptr: *anyopaque, item: *anyopaque) void,
    deinit: *const fn (ptr: *anyopaque) void,
};

pub fn get(self: Pool) ?*anyopaque {
    return self.vtable.get(self.ptr);
}

pub fn put(self: Pool, item: *anyopaque) void {
    self.vtable.put(self.ptr, item);
}

pub fn deinit(self: Pool) void {
    self.vtable.deinit(self.ptr);
}

pub fn init(pointer: anytype) Pool {
    const Ptr = @TypeOf(pointer);
    const info = @typeInfo(Ptr);
    if (info != .pointer or info.pointer.size != .one)
        @compileError("Pool.init expects a single-item pointer");

    const Impl = info.pointer.child;

    const Gen = struct {
        fn getFn(ptr: *anyopaque) ?*anyopaque {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.get();
        }

        fn putFn(ptr: *anyopaque, item: *anyopaque) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.put(item);
        }

        fn deinitFn(ptr: *anyopaque) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.deinit();
        }

        const vtable: VTable = .{
            .get = getFn,
            .put = putFn,
            .deinit = deinitFn,
        };
    };

    return .{
        .ptr = pointer,
        .vtable = &Gen.vtable,
    };
}

pub fn make(comptime lib: type, comptime T: type) type {
    return struct {
        allocator: embed.mem.Allocator,
        new_fn: ?New,
        new_ctx: ?*anyopaque,
        mutex: lib.Thread.Mutex = .{},
        free_entries: lib.DoublyLinkedList = .{},
        created_count: usize = 0,
        free_count: usize = 0,

        const Self = @This();
        const Entry = struct {
            free_node: lib.DoublyLinkedList.Node = .{},
            in_pool: bool = false,
            item: T = undefined,
        };

        pub const New = *const fn (ctx: ?*anyopaque, allocator: embed.mem.Allocator) ?T;

        pub fn init(
            allocator: embed.mem.Allocator,
            new_fn: ?New,
            new_ctx: ?*anyopaque,
        ) Self {
            return .{
                .allocator = allocator,
                .new_fn = new_fn,
                .new_ctx = new_ctx,
            };
        }

        pub fn get(self: *Self) ?*anyopaque {
            const item = self.getTyped() orelse return null;
            return @ptrCast(item);
        }

        pub fn getTyped(self: *Self) ?*T {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.free_entries.popFirst()) |node| {
                const entry: *Entry = @fieldParentPtr("free_node", node);
                entry.in_pool = false;
                self.free_count -= 1;
                return &entry.item;
            }

            const entry = self.allocator.create(Entry) catch return null;
            entry.* = .{};
            entry.item = if (self.new_fn) |new_fn|
                new_fn(self.new_ctx, self.allocator) orelse {
                    self.allocator.destroy(entry);
                    return null;
                }
            else
                lib.mem.zeroes(T);
            self.created_count += 1;
            return &entry.item;
        }

        pub fn put(self: *Self, item: *anyopaque) void {
            self.putTyped(@ptrCast(@alignCast(item)));
        }

        pub fn putTyped(self: *Self, item: *T) void {
            const entry: *Entry = @fieldParentPtr("item", item);

            self.mutex.lock();
            defer self.mutex.unlock();

            lib.debug.assert(!entry.in_pool);
            entry.in_pool = true;
            self.free_entries.append(&entry.free_node);
            self.free_count += 1;
        }

        pub fn deinit(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.free_count != self.created_count) {
                @panic("sync.Pool.deinit called with checked-out items");
            }

            while (self.free_entries.popFirst()) |node| {
                const entry: *Entry = @fieldParentPtr("free_node", node);
                self.allocator.destroy(entry);
            }
            self.free_entries = .{};
            self.created_count = 0;
            self.free_count = 0;
        }
    };
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            reuseCase(lib) catch |err| {
                t.logErrorf("sync.Pool reuse failed: {}", .{err});
                return false;
            };
            newCase(lib) catch |err| {
                t.logErrorf("sync.Pool new failed: {}", .{err});
                return false;
            };
            zeroInitCase(lib) catch |err| {
                t.logErrorf("sync.Pool zero init failed: {}", .{err});
                return false;
            };
            newReturnsNullCase(lib) catch |err| {
                t.logErrorf("sync.Pool null new failed: {}", .{err});
                return false;
            };
            erasedWrapperCase(lib) catch |err| {
                t.logErrorf("sync.Pool erased wrapper failed: {}", .{err});
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}

fn reuseCase(comptime lib: type) !void {
    const Item = struct {
        value: usize = 0,
    };
    const TypedPool = Pool.make(lib, Item);

    var pool = TypedPool.init(lib.testing.allocator, null, null);
    defer pool.deinit();

    const first = pool.getTyped() orelse return error.TestExpectedFirstItem;
    try lib.testing.expectEqual(@as(usize, 1), pool.created_count);
    try lib.testing.expectEqual(@as(usize, 0), pool.free_count);

    first.value = 41;
    pool.putTyped(first);
    try lib.testing.expectEqual(@as(usize, 1), pool.created_count);
    try lib.testing.expectEqual(@as(usize, 1), pool.free_count);

    const second = pool.getTyped() orelse return error.TestExpectedSecondItem;
    try lib.testing.expect(second == first);
    try lib.testing.expectEqual(@as(usize, 41), second.value);
    try lib.testing.expectEqual(@as(usize, 1), pool.created_count);
    try lib.testing.expectEqual(@as(usize, 0), pool.free_count);

    pool.putTyped(second);
}

fn newCase(comptime lib: type) !void {
    const Item = struct {
        value: usize = 0,
    };
    const TypedPool = Pool.make(lib, Item);
    const State = struct {
        next_value: usize = 7,
        allocator_ptr: usize = 0,
    };
    const Hooks = struct {
        fn newItem(ctx: ?*anyopaque, allocator: embed.mem.Allocator) ?Item {
            const state: *State = @ptrCast(@alignCast(ctx.?));
            state.allocator_ptr = @intFromPtr(allocator.ptr);
            const value = state.next_value;
            state.next_value += 1;
            return .{ .value = value };
        }
    };

    var state = State{};
    var pool = TypedPool.init(lib.testing.allocator, Hooks.newItem, @ptrCast(&state));
    defer pool.deinit();

    const first = pool.getTyped() orelse return error.TestExpectedFirstItem;
    const second = pool.getTyped() orelse return error.TestExpectedSecondItem;
    try lib.testing.expectEqual(@as(usize, 7), first.value);
    try lib.testing.expectEqual(@as(usize, 8), second.value);
    try lib.testing.expectEqual(@intFromPtr(lib.testing.allocator.ptr), state.allocator_ptr);
    try lib.testing.expectEqual(@as(usize, 2), pool.created_count);
    try lib.testing.expectEqual(@as(usize, 0), pool.free_count);
    pool.putTyped(first);
    pool.putTyped(second);
    try lib.testing.expectEqual(@as(usize, 2), pool.free_count);
}

fn zeroInitCase(comptime lib: type) !void {
    const Item = struct {
        a: usize,
        b: bool,
    };
    const TypedPool = Pool.make(lib, Item);

    var pool = TypedPool.init(lib.testing.allocator, null, null);
    defer pool.deinit();

    const item = pool.getTyped() orelse return error.TestExpectedItem;
    try lib.testing.expectEqual(@as(usize, 0), item.a);
    try lib.testing.expectEqual(false, item.b);
    pool.putTyped(item);
}

fn newReturnsNullCase(comptime lib: type) !void {
    const Item = struct {
        value: usize = 0,
    };
    const TypedPool = Pool.make(lib, Item);
    const Hooks = struct {
        fn newItem(_: ?*anyopaque, _: embed.mem.Allocator) ?Item {
            return null;
        }
    };

    var pool = TypedPool.init(lib.testing.allocator, Hooks.newItem, null);
    defer pool.deinit();

    try lib.testing.expect(pool.getTyped() == null);
    try lib.testing.expectEqual(@as(usize, 0), pool.created_count);
    try lib.testing.expectEqual(@as(usize, 0), pool.free_count);
}

fn erasedWrapperCase(comptime lib: type) !void {
    const Item = struct {
        value: usize = 0,
    };
    const TypedPool = Pool.make(lib, Item);
    const Hooks = struct {
        fn newItem(_: ?*anyopaque, _: embed.mem.Allocator) ?Item {
            return .{};
        }
    };

    var typed = TypedPool.init(lib.testing.allocator, Hooks.newItem, null);
    const erased = Pool.init(&typed);

    const raw = erased.get() orelse return error.TestExpectedErasedItem;
    const item: *Item = @ptrCast(@alignCast(raw));
    item.value = 55;
    erased.put(raw);

    const recycled_raw = erased.get() orelse return error.TestExpectedErasedItem;
    const recycled: *Item = @ptrCast(@alignCast(recycled_raw));
    try lib.testing.expect(recycled == item);
    try lib.testing.expectEqual(@as(usize, 55), recycled.value);
    erased.put(recycled_raw);

    erased.deinit();
}

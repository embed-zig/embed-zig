const Router = @This();
const State = @import("State.zig");

ptr: *const anyopaque,
vtable: *const VTable,

pub const Item = struct {
    screen_id: u32 = 0,
    arg0: u32 = 0,
    arg1: u32 = 0,
    flags: u32 = 0,
};

pub const VTable = struct {
    version: *const fn (ptr: *const anyopaque) u64,
    currentPage: *const fn (ptr: *const anyopaque) u32,
    depth: *const fn (ptr: *const anyopaque) usize,
    transitioning: *const fn (ptr: *const anyopaque) bool,
    item: *const fn (ptr: *const anyopaque, index: usize) ?Item,
};

pub fn version(self: Router) u64 {
    return self.vtable.version(self.ptr);
}

pub fn currentPage(self: Router) u32 {
    return self.vtable.currentPage(self.ptr);
}

pub fn depth(self: Router) usize {
    return self.vtable.depth(self.ptr);
}

pub fn transitioning(self: Router) bool {
    return self.vtable.transitioning(self.ptr);
}

pub fn item(self: Router, index: usize) ?Item {
    return self.vtable.item(self.ptr, index);
}

pub fn make(comptime lib: type) type {
    const Mutex = lib.Thread.Mutex;
    const RwLock = lib.Thread.RwLock;
    const ItemList = lib.ArrayList(Item);

    return struct {
        const Self = @This();

        pub const Error = error{OutOfMemory};

        allocator: lib.mem.Allocator,

        running_mu: Mutex = .{},
        running_items: ItemList = .empty,
        running_transitioning: bool = false,

        released_mu: RwLock = .{},
        released_items: ItemList = .empty,
        released_transitioning: bool = false,
        version_value: u64 = 0,

        pub fn init(allocator: lib.mem.Allocator, initial: Item) Error!Self {
            var self: Self = .{
                .allocator = allocator,
            };
            try self.running_items.append(allocator, initial);
            errdefer self.running_items.deinit(allocator);
            try self.released_items.append(allocator, initial);
            errdefer self.released_items.deinit(allocator);
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.running_items.deinit(self.allocator);
            self.released_items.deinit(self.allocator);
            self.running_items = .empty;
            self.released_items = .empty;
        }

        pub fn handle(self: *Self) Router {
            return .{
                .ptr = self,
                .vtable = &VTableGen.vtable,
            };
        }

        pub fn state(self: *Self) State {
            self.released_mu.lockShared();
            defer self.released_mu.unlockShared();
            return .{
                .current_page = currentPageLocked(self.released_items.items),
                .transitioning = self.released_transitioning,
                .version = self.version_value,
            };
        }

        pub fn version(self: *Self) u64 {
            self.released_mu.lockShared();
            defer self.released_mu.unlockShared();
            return self.version_value;
        }

        pub fn currentPage(self: *Self) u32 {
            self.released_mu.lockShared();
            defer self.released_mu.unlockShared();
            return currentPageLocked(self.released_items.items);
        }

        pub fn depth(self: *Self) usize {
            self.released_mu.lockShared();
            defer self.released_mu.unlockShared();
            return self.released_items.items.len;
        }

        pub fn transitioning(self: *Self) bool {
            self.released_mu.lockShared();
            defer self.released_mu.unlockShared();
            return self.released_transitioning;
        }

        pub fn item(self: *Self, index: usize) ?Item {
            self.released_mu.lockShared();
            defer self.released_mu.unlockShared();
            if (index >= self.released_items.items.len) return null;
            return self.released_items.items[index];
        }

        pub fn push(self: *Self, next_item: Item) Error!bool {
            self.running_mu.lock();
            defer self.running_mu.unlock();
            try self.running_items.append(self.allocator, next_item);
            return true;
        }

        pub fn replace(self: *Self, next_item: Item) bool {
            self.running_mu.lock();
            defer self.running_mu.unlock();
            if (self.running_items.items.len == 0) {
                self.running_items.append(self.allocator, next_item) catch @panic("zux.component.ui.route.Router.replace failed to grow route stack");
                return true;
            }
            if (itemEql(self.running_items.items[self.running_items.items.len - 1], next_item)) return false;
            self.running_items.items[self.running_items.items.len - 1] = next_item;
            return true;
        }

        pub fn reset(self: *Self, next_item: Item) bool {
            self.running_mu.lock();
            defer self.running_mu.unlock();
            if (self.running_items.items.len == 0) {
                self.running_items.append(self.allocator, next_item) catch @panic("zux.component.ui.route.Router.reset failed to grow route stack");
                return true;
            }
            self.running_items.items[0] = next_item;
            self.running_items.items.len = 1;
            return true;
        }

        pub fn pop(self: *Self) bool {
            self.running_mu.lock();
            defer self.running_mu.unlock();
            if (self.running_items.items.len <= 1) return false;
            _ = self.running_items.pop();
            return true;
        }

        pub fn popToRoot(self: *Self) bool {
            self.running_mu.lock();
            defer self.running_mu.unlock();
            if (self.running_items.items.len <= 1) return false;
            self.running_items.items.len = 1;
            return true;
        }

        pub fn setTransitioning(self: *Self, value: bool) bool {
            self.running_mu.lock();
            defer self.running_mu.unlock();
            if (self.running_transitioning == value) return false;
            self.running_transitioning = value;
            return true;
        }

        pub fn tick(self: *Self) bool {
            self.running_mu.lock();
            self.released_mu.lock();
            defer self.released_mu.unlock();
            defer self.running_mu.unlock();

            if (!routeChangedLocked(
                self.running_items.items,
                self.running_transitioning,
                self.released_items.items,
                self.released_transitioning,
            )) return false;

            self.released_items.clearRetainingCapacity();
            self.released_items.appendSlice(self.allocator, self.running_items.items) catch @panic("zux.component.ui.route.Router.tick failed to snapshot route stack");
            self.released_transitioning = self.running_transitioning;
            self.version_value += 1;
            return true;
        }

        fn currentPageLocked(items: []const Item) u32 {
            if (items.len == 0) return 0;
            return items[items.len - 1].screen_id;
        }

        fn routeChangedLocked(
            running_items: []const Item,
            running_transitioning: bool,
            released_items: []const Item,
            released_transitioning: bool,
        ) bool {
            if (running_transitioning != released_transitioning) return true;
            if (running_items.len != released_items.len) return true;
            for (running_items, released_items) |a, b| {
                if (!itemEql(a, b)) return true;
            }
            return false;
        }

        fn itemEql(a: Item, b: Item) bool {
            return a.screen_id == b.screen_id and
                a.arg0 == b.arg0 and
                a.arg1 == b.arg1 and
                a.flags == b.flags;
        }

        const VTableGen = struct {
            fn versionFn(ptr: *const anyopaque) u64 {
                const self: *Self = @ptrCast(@alignCast(@constCast(ptr)));
                return self.version();
            }

            fn currentPageFn(ptr: *const anyopaque) u32 {
                const self: *Self = @ptrCast(@alignCast(@constCast(ptr)));
                return self.currentPage();
            }

            fn depthFn(ptr: *const anyopaque) usize {
                const self: *Self = @ptrCast(@alignCast(@constCast(ptr)));
                return self.depth();
            }

            fn transitioningFn(ptr: *const anyopaque) bool {
                const self: *Self = @ptrCast(@alignCast(@constCast(ptr)));
                return self.transitioning();
            }

            fn itemFn(ptr: *const anyopaque, index: usize) ?Item {
                const self: *Self = @ptrCast(@alignCast(@constCast(ptr)));
                return self.item(index);
            }

            const vtable = VTable{
                .version = versionFn,
                .currentPage = currentPageFn,
                .depth = depthFn,
                .transitioning = transitioningFn,
                .item = itemFn,
            };
        };
    };
}

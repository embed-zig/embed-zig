const binding = @import("binding.zig");

const Handle = binding.Handle;
const pd_true = binding.pd_true;

pub const Error = error{CreateFailed};

handle: Handle = null,

const Self = @This();

pub fn initBinary(initially_available: bool) Error!Self {
    var self = Self{
        .handle = binding.espz_semaphore_create_binary() orelse return error.CreateFailed,
    };
    errdefer self.deinit();

    if (initially_available) {
        _ = binding.espz_semaphore_give(self.handle);
    }
    return self;
}

pub fn initCounting(max_count: u32, initial_count: u32) Error!Self {
    return .{
        .handle = binding.espz_semaphore_create_counting(max_count, initial_count) orelse
            return error.CreateFailed,
    };
}

pub fn deinit(self: *Self) void {
    if (self.handle) |handle| {
        binding.espz_semaphore_delete(handle);
        self.handle = null;
    }
}

pub fn take(self: *Self, ticks: u32) bool {
    return binding.espz_semaphore_take(self.handle, ticks) == pd_true;
}

pub fn give(self: *Self) bool {
    return binding.espz_semaphore_give(self.handle) == pd_true;
}

pub fn rawHandle(self: *const Self) Handle {
    return self.handle;
}

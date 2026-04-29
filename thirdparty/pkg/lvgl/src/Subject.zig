const glib = @import("glib");
const binding = @import("binding.zig");

const Self = @This();

handle: *binding.Subject,

pub const Type = binding.SubjectType;
pub const InitError = error{OutOfMemory};

pub fn rawPtr(self: *Self) *binding.Subject {
    return self.handle;
}

pub fn rawConstPtr(self: *const Self) *const binding.Subject {
    return self.handle;
}

pub fn initInt(value: i32) InitError!Self {
    const handle = binding.embed_lv_subject_create() orelse return error.OutOfMemory;
    binding.lv_subject_init_int(handle, value);
    return .{ .handle = handle };
}

pub fn initPointer(value: ?*anyopaque) InitError!Self {
    const handle = binding.embed_lv_subject_create() orelse return error.OutOfMemory;
    binding.lv_subject_init_pointer(handle, value);
    return .{ .handle = handle };
}

/// `buffer` and `prev_buffer` are stored by reference and must outlive the subject.
pub fn initString(buffer: [:0]u8, prev_buffer: ?[:0]u8, initial_value: [:0]const u8) InitError!Self {
    const handle = binding.embed_lv_subject_create() orelse return error.OutOfMemory;
    const prev_ptr = if (prev_buffer) |buf| buf.ptr else null;
    binding.lv_subject_init_string(handle, buffer.ptr, prev_ptr, buffer.len, initial_value.ptr);
    return .{ .handle = handle };
}

pub fn deinit(self: *Self) void {
    binding.lv_subject_deinit(self.handle);
    binding.embed_lv_subject_destroy(self.handle);
}

pub fn setInt(self: *Self, value: i32) void {
    binding.lv_subject_set_int(self.handle, value);
}

pub fn getInt(self: *Self) i32 {
    return binding.lv_subject_get_int(self.handle);
}

pub fn previousInt(self: *Self) i32 {
    return binding.lv_subject_get_previous_int(self.handle);
}

pub fn setMinInt(self: *Self, value: i32) void {
    binding.lv_subject_set_min_value_int(self.handle, value);
}

pub fn setMaxInt(self: *Self, value: i32) void {
    binding.lv_subject_set_max_value_int(self.handle, value);
}

pub fn setPointer(self: *Self, value: ?*anyopaque) void {
    binding.lv_subject_set_pointer(self.handle, value);
}

pub fn getPointer(self: *Self) ?*const anyopaque {
    return binding.lv_subject_get_pointer(self.handle);
}

pub fn previousPointer(self: *Self) ?*const anyopaque {
    return binding.lv_subject_get_previous_pointer(self.handle);
}

pub fn copyString(self: *Self, value: [:0]const u8) void {
    binding.lv_subject_copy_string(self.handle, value.ptr);
}

pub fn getString(self: *Self) [*:0]const u8 {
    return binding.lv_subject_get_string(self.handle);
}

pub fn previousString(self: *Self) ?[*:0]const u8 {
    return binding.lv_subject_get_previous_string(self.handle);
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const Impl = struct {
        fn integer_subject_tracks_current_and_previous_values(_: *glib.testing.T, _: glib.std.mem.Allocator) !void {
            binding.lv_init();
            defer binding.lv_deinit();

            var subject = try Self.initInt(12);
            defer subject.deinit();

            try grt.std.testing.expectEqual(@as(i32, 12), subject.getInt());

            subject.setInt(34);

            try grt.std.testing.expectEqual(@as(i32, 34), subject.getInt());
            try grt.std.testing.expectEqual(@as(i32, 12), subject.previousInt());
        }

        fn pointer_subject_tracks_previous_pointer_value(_: *glib.testing.T, _: glib.std.mem.Allocator) !void {
            binding.lv_init();
            defer binding.lv_deinit();

            var first: u8 = 1;
            var second: u8 = 2;
            var subject = try Self.initPointer(&first);
            defer subject.deinit();

            try grt.std.testing.expectEqual(@as(?*const anyopaque, @ptrCast(&first)), subject.getPointer());
            try grt.std.testing.expectEqual(@as(?*const anyopaque, @ptrCast(&first)), subject.previousPointer());

            subject.setPointer(&second);

            try grt.std.testing.expectEqual(@as(?*const anyopaque, @ptrCast(&second)), subject.getPointer());
            try grt.std.testing.expectEqual(@as(?*const anyopaque, @ptrCast(&first)), subject.previousPointer());
        }

        fn string_subject_copies_into_owned_buffers(_: *glib.testing.T, _: glib.std.mem.Allocator) !void {
            binding.lv_init();
            defer binding.lv_deinit();

            var current_buffer = [_:0]u8{0} ** 16;
            var previous_buffer = [_:0]u8{0} ** 16;
            var subject = try Self.initString(current_buffer[0.. :0], previous_buffer[0.. :0], "hi");
            defer subject.deinit();

            subject.copyString("bye");

            try grt.std.testing.expectEqualStrings("bye", grt.std.mem.span(subject.getString()));
            try grt.std.testing.expectEqualStrings("hi", grt.std.mem.span(subject.previousString().?));
        }

        fn string_subject_uses_caller_provided_storage(_: *glib.testing.T, _: glib.std.mem.Allocator) !void {
            binding.lv_init();
            defer binding.lv_deinit();

            var current_buffer = [_:0]u8{0} ** 16;
            var previous_buffer = [_:0]u8{0} ** 16;
            const current = current_buffer[0.. :0];
            const previous = previous_buffer[0.. :0];
            var subject = try Self.initString(current, previous, "hi");
            defer subject.deinit();

            subject.copyString("bye");

            try grt.std.testing.expectEqual(@intFromPtr(current.ptr), @intFromPtr(subject.getString()));
            try grt.std.testing.expectEqual(@intFromPtr(previous.ptr), @intFromPtr(subject.previousString().?));
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("lvgl/unit_tests/Subject/integer_subject_tracks_current_and_previous_values", glib.testing.TestRunner.fromFn(grt.std, 1024 * 1024, Impl.integer_subject_tracks_current_and_previous_values));
            t.run("lvgl/unit_tests/Subject/pointer_subject_tracks_previous_pointer_value", glib.testing.TestRunner.fromFn(grt.std, 1024 * 1024, Impl.pointer_subject_tracks_previous_pointer_value));
            t.run("lvgl/unit_tests/Subject/string_subject_copies_into_owned_buffers", glib.testing.TestRunner.fromFn(grt.std, 1024 * 1024, Impl.string_subject_copies_into_owned_buffers));
            t.run("lvgl/unit_tests/Subject/string_subject_uses_caller_provided_storage", glib.testing.TestRunner.fromFn(grt.std, 1024 * 1024, Impl.string_subject_uses_caller_provided_storage));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}

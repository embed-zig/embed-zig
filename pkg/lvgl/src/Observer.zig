const binding = @import("binding.zig");

const Self = @This();

handle: *binding.Observer,

pub fn fromRaw(handle: *binding.Observer) Self {
    return .{ .handle = handle };
}

pub fn raw(self: *const Self) *binding.Observer {
    return self.handle;
}

pub fn remove(self: *Self) void {
    binding.lv_observer_remove(self.handle);
}

pub fn target(self: *const Self) ?*anyopaque {
    return binding.lv_observer_get_target(self.handle);
}

pub fn userData(self: *const Self) ?*anyopaque {
    return binding.lv_observer_get_user_data(self.handle);
}

test "lvgl/unit_tests/Observer/raw_handle_roundtrip" {
    const testing = @import("std").testing;

    const raw_handle: *binding.Observer = @ptrFromInt(1);
    const observer = Self.fromRaw(raw_handle);

    try testing.expectEqual(raw_handle, observer.raw());

    _ = Self.remove;
    _ = Self.target;
    _ = Self.userData;
}

test "lvgl/unit_tests/Observer/can_observe_subject_updates" {
    const testing = @import("std").testing;
    const Subject = @import("Subject.zig");

    const CallbackCtx = struct {
        calls: usize = 0,
        observer: ?*binding.Observer = null,
        subject: ?*binding.Subject = null,
        target: ?*anyopaque = null,
        user_data: ?*anyopaque = null,

        fn callback(observer: ?*binding.Observer, subject: ?*binding.Subject) callconv(.c) void {
            const Context = @This();
            const obs = observer orelse return;
            const subj = subject orelse return;
            const ctx: *Context = @ptrCast(@alignCast(binding.lv_observer_get_user_data(obs).?));
            ctx.calls += 1;
            ctx.observer = obs;
            ctx.subject = subj;
            ctx.target = binding.lv_observer_get_target(obs);
            ctx.user_data = binding.lv_observer_get_user_data(obs);
        }
    };

    var subject = try Subject.initInt(12);
    defer subject.deinit();

    var ctx = CallbackCtx{};
    const raw_observer = binding.lv_subject_add_observer(subject.rawPtr(), CallbackCtx.callback, &ctx) orelse {
        return error.ExpectedObserver;
    };
    var observer = Self.fromRaw(raw_observer);
    const calls_after_add = ctx.calls;

    subject.setInt(34);

    try testing.expectEqual(calls_after_add + 1, ctx.calls);
    try testing.expectEqual(raw_observer, ctx.observer.?);
    try testing.expectEqual(subject.rawPtr(), ctx.subject.?);
    try testing.expectEqual(@as(?*anyopaque, null), observer.target());
    try testing.expectEqual(@as(?*anyopaque, null), ctx.target);
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&ctx)), observer.userData());
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&ctx)), ctx.user_data);

    observer.remove();
}

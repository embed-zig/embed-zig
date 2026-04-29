const glib = @import("glib");
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

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const Impl = struct {
        fn raw_handle_roundtrip(_: *glib.testing.T, _: glib.std.mem.Allocator) !void {
            const raw_handle: *binding.Observer = @ptrFromInt(1);
            const observer = Self.fromRaw(raw_handle);

            try grt.std.testing.expectEqual(raw_handle, observer.raw());

            _ = Self.remove;
            _ = Self.target;
            _ = Self.userData;
        }

        fn can_observe_subject_updates(_: *glib.testing.T, _: glib.std.mem.Allocator) !void {
            const Subject = @import("Subject.zig");

            binding.lv_init();
            defer binding.lv_deinit();

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

            try grt.std.testing.expectEqual(calls_after_add + 1, ctx.calls);
            try grt.std.testing.expectEqual(raw_observer, ctx.observer.?);
            try grt.std.testing.expectEqual(subject.rawPtr(), ctx.subject.?);
            try grt.std.testing.expectEqual(@as(?*anyopaque, null), observer.target());
            try grt.std.testing.expectEqual(@as(?*anyopaque, null), ctx.target);
            try grt.std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&ctx)), observer.userData());
            try grt.std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&ctx)), ctx.user_data);

            observer.remove();
        }

        fn remove_stops_future_subject_notifications(_: *glib.testing.T, _: glib.std.mem.Allocator) !void {
            const Subject = @import("Subject.zig");

            binding.lv_init();
            defer binding.lv_deinit();

            const CallbackCtx = struct {
                calls: usize = 0,

                fn callback(observer: ?*binding.Observer, _: ?*binding.Subject) callconv(.c) void {
                    const obs = observer orelse return;
                    const ctx: *@This() = @ptrCast(@alignCast(binding.lv_observer_get_user_data(obs).?));
                    ctx.calls += 1;
                }
            };

            var subject = try Subject.initInt(1);
            defer subject.deinit();

            var ctx = CallbackCtx{};
            const raw_observer = binding.lv_subject_add_observer(subject.rawPtr(), CallbackCtx.callback, &ctx) orelse {
                return error.ExpectedObserver;
            };
            var observer = Self.fromRaw(raw_observer);
            const calls_after_add = ctx.calls;

            subject.setInt(2);
            try grt.std.testing.expectEqual(calls_after_add + 1, ctx.calls);

            observer.remove();
            const calls_after_remove = ctx.calls;
            subject.setInt(3);

            try grt.std.testing.expectEqual(calls_after_remove, ctx.calls);
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

            t.run("lvgl/unit_tests/Observer/raw_handle_roundtrip", glib.testing.TestRunner.fromFn(grt.std, 1024 * 1024, Impl.raw_handle_roundtrip));
            t.run("lvgl/unit_tests/Observer/can_observe_subject_updates", glib.testing.TestRunner.fromFn(grt.std, 1024 * 1024, Impl.can_observe_subject_updates));
            t.run("lvgl/unit_tests/Observer/remove_stops_future_subject_notifications", glib.testing.TestRunner.fromFn(grt.std, 1024 * 1024, Impl.remove_stops_future_subject_notifications));
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

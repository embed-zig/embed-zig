//! lvgl OS integration smoke tests.

const glib = @import("glib");
const embed = @import("embed");
const lvgl = @import("../../../../lvgl.zig");

const binding = lvgl.binding;

pub fn make(comptime grt: type) glib.testing.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            const Cases = struct {
                fn generalLockIsRecursive() !void {
                    lvgl.init();
                    defer lvgl.deinit();

                    binding.lv_lock();
                    binding.lv_lock();
                    binding.lv_unlock();
                    binding.lv_unlock();
                }

                fn customMutexLifecycle() !void {
                    var mutex = embed.mem.zeroes(binding.Mutex);

                    try grt.std.testing.expectEqual(binding.LV_RESULT_OK, binding.lv_mutex_init(&mutex));
                    defer {
                        if (binding.lv_mutex_delete(&mutex) != binding.LV_RESULT_OK) {
                            @panic("lv_mutex_delete failed");
                        }
                    }

                    try grt.std.testing.expectEqual(binding.LV_RESULT_OK, binding.lv_mutex_lock(&mutex));
                    try grt.std.testing.expectEqual(binding.LV_RESULT_OK, binding.lv_mutex_lock(&mutex));
                    try grt.std.testing.expectEqual(binding.LV_RESULT_OK, binding.lv_mutex_unlock(&mutex));
                    try grt.std.testing.expectEqual(binding.LV_RESULT_OK, binding.lv_mutex_unlock(&mutex));
                    try grt.std.testing.expectEqual(binding.LV_RESULT_INVALID, binding.lv_mutex_lock_isr(&mutex));
                }

                fn customThreadAndSyncLifecycle() !void {
                    var sync = embed.mem.zeroes(binding.ThreadSync);
                    try grt.std.testing.expectEqual(binding.LV_RESULT_OK, binding.lv_thread_sync_init(&sync));
                    defer {
                        if (binding.lv_thread_sync_delete(&sync) != binding.LV_RESULT_OK) {
                            @panic("lv_thread_sync_delete failed");
                        }
                    }

                    var thread = embed.mem.zeroes(binding.Thread);
                    defer if (thread.impl != null) {
                        if (binding.lv_thread_delete(&thread) != binding.LV_RESULT_OK) {
                            @panic("lv_thread_delete failed");
                        }
                    };

                    var did_run = embed.atomic.Value(bool).init(false);
                    var ctx = ThreadContext{
                        .sync = &sync,
                        .did_run = &did_run,
                    };

                    try grt.std.testing.expectEqual(
                        binding.LV_RESULT_OK,
                        binding.lv_thread_init(&thread, "test-worker", @as(binding.ThreadPrio, 0), threadEntry, 0, &ctx),
                    );
                    try grt.std.testing.expectEqual(binding.LV_RESULT_OK, binding.lv_thread_sync_wait(&sync));
                    try grt.std.testing.expect(did_run.load(.acquire));
                    try grt.std.testing.expectEqual(binding.LV_RESULT_OK, binding.lv_thread_delete(&thread));
                    try grt.std.testing.expectEqual(binding.LV_RESULT_INVALID, binding.lv_thread_sync_signal_isr(&sync));
                }

                fn customThreadSyncRetainsSignalsAcrossRepeatedWaits() !void {
                    var sync = embed.mem.zeroes(binding.ThreadSync);
                    try grt.std.testing.expectEqual(binding.LV_RESULT_OK, binding.lv_thread_sync_init(&sync));
                    defer {
                        if (binding.lv_thread_sync_delete(&sync) != binding.LV_RESULT_OK) {
                            @panic("lv_thread_sync_delete failed");
                        }
                    }

                    try grt.std.testing.expectEqual(binding.LV_RESULT_OK, binding.lv_thread_sync_signal(&sync));
                    try grt.std.testing.expectEqual(binding.LV_RESULT_OK, binding.lv_thread_sync_wait(&sync));
                    try grt.std.testing.expectEqual(binding.LV_RESULT_OK, binding.lv_thread_sync_signal(&sync));
                    try grt.std.testing.expectEqual(binding.LV_RESULT_OK, binding.lv_thread_sync_wait(&sync));
                }
            };

            Cases.generalLockIsRecursive() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            Cases.customMutexLifecycle() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            Cases.customThreadAndSyncLifecycle() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            Cases.customThreadSyncRetainsSignalsAcrossRepeatedWaits() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = allocator;
            grt.std.testing.allocator.destroy(self);
        }
    };

    const runner = grt.std.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return glib.testing.TestRunner.make(Runner).new(runner);
}

const ThreadContext = struct {
    sync: *binding.ThreadSync,
    did_run: *embed.atomic.Value(bool),
};

fn threadEntry(user_data: ?*anyopaque) callconv(.c) void {
    const ctx: *ThreadContext = @ptrCast(@alignCast(user_data.?));
    ctx.did_run.store(true, .release);
    _ = binding.lv_thread_sync_signal(ctx.sync);
}

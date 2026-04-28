//! Global millisecond clock for LVGL (`lv_tick_inc` / `lv_tick_get`).
//!
//! Drive time by calling [`inc`] from a periodic context (RTOS tick, timer thread, or ISR where
//! appropriate) with the **elapsed** milliseconds since the last call. Call [`timerHandler`] from
//! your UI / LVGL driver thread so timers and animations run.
//!
//! **Threading:** embed-zig enables LVGL's **`LV_OS_CUSTOM`** backend and supplies a bundled Zig
//! implementation of the required mutex, thread, and sync primitives.
//!
//! `lv_tick_inc` is often safe from a tick interrupt when the tick counter access matches your
//! platform’s alignment and LVGL’s expectations; still follow LVGL + your RTOS docs for ISR vs task.

const glib = @import("glib");
const binding = @import("binding.zig");

pub const GetCb = binding.TickGetCb;
pub const DelayCb = binding.DelayCb;
pub const no_timer_ready: u32 = binding.LV_NO_TIMER_READY;

pub fn inc(period_ms: u32) void {
    binding.lv_tick_inc(period_ms);
}

pub fn get() u32 {
    return binding.lv_tick_get();
}

pub fn elaps(prev_tick: u32) u32 {
    return binding.lv_tick_elaps(prev_tick);
}

pub fn diff(tick: u32, prev_tick: u32) u32 {
    return binding.lv_tick_diff(tick, prev_tick);
}

pub fn delayMs(ms: u32) void {
    binding.lv_delay_ms(ms);
}

pub fn setDelayCb(cb: DelayCb) void {
    binding.lv_delay_set_cb(cb);
}

pub fn setGetCb(cb: GetCb) void {
    binding.lv_tick_set_cb(cb);
}

pub fn getGetCb() GetCb {
    return binding.lv_tick_get_cb();
}

/// Run LVGL’s internal timers; returns suggested milliseconds until the next call.
pub fn timerHandler() u32 {
    return binding.lv_timer_handler();
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const Impl = struct {
        fn inc_updates_elaps(_: *glib.testing.T, _: glib.std.mem.Allocator) !void {
            binding.lv_init();
            defer binding.lv_deinit();

            const t0 = get();
            inc(41);
            try grt.std.testing.expect(elaps(t0) >= 41);
        }

        fn timer_handler_runs_after_tick(_: *glib.testing.T, _: glib.std.mem.Allocator) !void {
            binding.lv_init();
            defer binding.lv_deinit();

            inc(5);
            const next = timerHandler();
            try grt.std.testing.expectEqual(no_timer_ready, next);
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

            t.run("lvgl/unit_tests/Tick/inc_updates_elaps", glib.testing.TestRunner.fromFn(grt.std, 1024 * 1024, Impl.inc_updates_elaps));
            t.run("lvgl/unit_tests/Tick/timer_handler_runs_after_tick", glib.testing.TestRunner.fromFn(grt.std, 1024 * 1024, Impl.timer_handler_runs_after_tick));
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

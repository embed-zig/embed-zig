const glib = @import("glib");
const lvgl = @import("lvgl");

const ScreenMod = @import("Screen.zig");

pub fn make(comptime grt: type, comptime ZuxAppType: type) type {
    const Impl = ZuxAppType.ImplType;
    const LvglRuntimeType = lvgl.embed.LvglZuxRuntime.make(grt, Impl);
    const State = @FieldType(ZuxAppType.Store.Stores, "speed_test").StateType;
    const Screen = ScreenMod.make(State);
    const Command = enum(u8) {
        render,
    };
    const CommandChannel = grt.sync.Channel(Command);
    const AtomicBool = grt.std.atomic.Value(bool);
    const log = grt.std.log.scoped(.ble_speed_ui);

    return struct {
        const Self = @This();

        pub const Config = struct {
            task_options: glib.task.Options = .{
                .min_stack_size = 16 * 1024,
            },
            command_capacity: usize = 4,
        };

        allocator: glib.std.mem.Allocator,
        zux_app: *ZuxAppType,
        config: Config,
        commands: CommandChannel,
        command_open: bool = true,
        stop: AtomicBool = AtomicBool.init(false),
        task: ?grt.task.Handle = null,
        render_seq: u64 = 0,

        pub fn init(allocator: glib.std.mem.Allocator, zux_app: *ZuxAppType, config: Config) !Self {
            return .{
                .allocator = allocator,
                .zux_app = zux_app,
                .config = config,
                .commands = try CommandChannel.make(allocator, config.command_capacity),
            };
        }

        pub fn start(self: *Self) !void {
            if (self.task != null) return;
            self.stop.store(false, .release);
            self.task = try grt.task.go(
                "zux/ble_speed/ui",
                self.config.task_options,
                glib.task.Routine.init(self, loop),
            );
            try self.requestRender();
        }

        pub fn requestRender(self: *Self) !void {
            if (!self.command_open) return;
            const result = try self.commands.sendTimeout(.render, 0);
            if (!result.ok) {
                log.warn("render request dropped: ui command queue full", .{});
            }
        }

        pub fn deinit(self: *Self) void {
            self.stop.store(true, .release);
            if (self.command_open) {
                self.command_open = false;
                self.commands.close();
            }
            if (self.task) |task| {
                task.join();
                self.task = null;
            }
            self.commands.deinit();
            self.* = undefined;
        }

        fn loop(self: *Self) void {
            self.run() catch |err| {
                log.err("ui loop stopped: {s}", .{@errorName(err)});
            };
        }

        fn run(self: *Self) !void {
            var lvgl_runtime = try LvglRuntimeType.init(.{
                .allocator = self.allocator,
                .threaded = false,
            });
            defer lvgl_runtime.deinit();

            var render_state: RenderState = .{};
            lvgl_runtime.setRenderFunc(&render_state, renderLvgl);

            while (!self.stop.load(.acquire)) {
                const first = self.commands.recv() catch break;
                if (!first.ok) break;
                render_state.state = self.zux_app.store.stores.speed_test.get();
                try self.renderOnce(&lvgl_runtime, &render_state);

                var has_latest = false;
                while (true) {
                    const next = self.commands.recvTimeout(0) catch break;
                    if (!next.ok) return;
                    render_state.state = self.zux_app.store.stores.speed_test.get();
                    has_latest = true;
                }
                if (has_latest) {
                    try self.renderOnce(&lvgl_runtime, &render_state);
                    render_state.state = null;
                }
            }
        }

        fn renderOnce(self: *Self, lvgl_runtime: *LvglRuntimeType, render_state: *RenderState) !void {
            self.render_seq += 1;
            try lvgl_runtime.render(&self.zux_app.impl);
            render_state.state = null;
        }

        const RenderState = struct {
            screen: ?Screen = null,
            state: ?State = null,
        };

        fn renderLvgl(render_state: *RenderState, runtime: *LvglRuntimeType, app: *Impl) !void {
            try ensureScreen(render_state, runtime, app);
            const state = render_state.state orelse app.store().stores.speed_test.get();
            render_state.screen.?.setState(state, sampleRuntimeOverlay(grt));
        }

        fn ensureScreen(render_state: *RenderState, runtime: *LvglRuntimeType, app: *Impl) !void {
            if (render_state.screen != null) return;

            const display_state = app.store().stores.display.get();
            var display = app.display(.display);
            try display.setEnabled(display_state.enabled);
            try display.setBrightness(display_state.brightness);
            try runtime.ensureDisplay(display);
            render_state.screen = try Screen.init(runtime.displayHandle());
        }

        fn sampleRuntimeOverlay(comptime runtime_grt: type) Screen.RuntimeOverlay {
            var overlay: Screen.RuntimeOverlay = .{};

            var cpu_stats: runtime_grt.system.CpuStats = .{};
            runtime_grt.system.readCpuStats(&cpu_stats) catch |err| switch (err) {
                error.Unsupported => {},
                else => log.warn("runtime cpu stats unavailable: {s}", .{@errorName(err)}),
            };
            overlay.cpu_core_count = @intCast(@min(cpu_stats.core_count, overlay.idle_percent.len));
            overlay.cpu_valid = cpu_stats.core_count > 0;
            for (0..overlay.cpu_core_count) |i| {
                overlay.idle_percent[i] = 100 - @min(cpu_stats.cores[i].usage_percent, 100);
            }

            var memory_stats: runtime_grt.system.MemoryStats = .{};
            runtime_grt.system.readMemoryStats(&memory_stats) catch |err| switch (err) {
                error.Unsupported => {},
                else => log.warn("runtime memory stats unavailable: {s}", .{@errorName(err)}),
            };
            overlay.memory_valid = memory_stats.internal_total != 0 or memory_stats.psram_total != 0;
            overlay.diram_free = memory_stats.internal_free;
            overlay.psram_free = memory_stats.psram_free;

            return overlay;
        }
    };
}

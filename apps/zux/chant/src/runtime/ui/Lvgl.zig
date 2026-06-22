const glib = @import("glib");
const lvgl = @import("lvgl");

const consts = @import("../../consts.zig");
const ScreenMod = @import("Screen.zig");

pub fn make(comptime grt: type, comptime ZuxAppType: type) type {
    const Impl = ZuxAppType.ImplType;
    const LvglRuntimeType = lvgl.embed.LvglZuxRuntime.make(grt, Impl);
    const Screen = ScreenMod.make(ZuxAppType);
    const RawTouch = @FieldType(ZuxAppType.Message.Event, "raw_touch");
    const Command = union(enum) {
        render,
        touch: RawTouch,
    };
    const CommandChannel = grt.sync.Channel(Command);
    const AtomicBool = grt.std.atomic.Value(bool);
    const log = grt.std.log.scoped(.chant_ui);
    const render_interval = 200 * glib.time.duration.MilliSecond;

    return struct {
        const Runtime = @This();

        pub const Config = struct {
            task_options: glib.task.Options = .{
                .min_stack_size = 16 * 1024,
            },
            command_capacity: usize = 32,
        };

        allocator: glib.std.mem.Allocator,
        zux_app: *ZuxAppType,
        config: Config,
        commands: CommandChannel,
        command_open: bool = true,
        stop: AtomicBool = AtomicBool.init(false),
        task: ?grt.task.Handle = null,
        render_seq: u64 = 0,

        pub fn init(allocator: glib.std.mem.Allocator, zux_app: *ZuxAppType, config: Config) !Runtime {
            return .{
                .allocator = allocator,
                .zux_app = zux_app,
                .config = config,
                .commands = try CommandChannel.make(allocator, config.command_capacity),
            };
        }

        pub fn start(self: *Runtime) !void {
            if (self.task != null) return;
            self.stop.store(false, .release);
            self.task = try grt.task.go(
                "zux/chant/ui",
                self.config.task_options,
                glib.task.Routine.init(self, loop),
            );
            try self.requestRender();
        }

        pub fn requestRender(self: *Runtime) !void {
            try self.sendCommand(.render, "render");
        }

        pub fn reduce(self: *Runtime, stores: anytype, message: anytype, emit: anytype) !void {
            _ = stores;
            _ = emit;

            switch (message.body) {
                .raw_touch => |raw_touch| try self.sendCommand(.{ .touch = raw_touch }, "touch"),
                else => {},
            }
        }

        pub fn deinit(self: *Runtime) void {
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

        fn sendCommand(self: *Runtime, command: Command, comptime label: []const u8) !void {
            if (!self.command_open) return;
            const result = try self.commands.sendTimeout(command, 0);
            if (!result.ok) {
                log.warn("{s} request dropped: ui command queue full", .{label});
            }
        }

        fn loop(self: *Runtime) void {
            self.run() catch |err| {
                log.err("ui loop stopped: {s}", .{@errorName(err)});
            };
        }

        fn run(self: *Runtime) !void {
            log.info("ui thread started", .{});
            var lvgl_runtime = try LvglRuntimeType.init(.{
                .allocator = self.allocator,
                .threaded = false,
                .command_capacity = self.config.command_capacity,
            });
            defer lvgl_runtime.deinit();
            lvgl_runtime.bindZuxApp(&self.zux_app.impl);

            var render_state: RenderState = .{};
            lvgl_runtime.setRenderFunc(&render_state, render);

            var pending_render = false;
            var last_render_at: ?glib.time.instant.Time = null;
            while (!self.stop.load(.acquire)) {
                const timeout = waitTimeout(pending_render, last_render_at);
                const first = if (timeout) |duration|
                    self.commands.recvTimeout(duration) catch {
                        if (pending_render and canRender(last_render_at)) {
                            try self.renderOnce(&lvgl_runtime, &render_state, &last_render_at);
                            pending_render = false;
                        } else {
                            _ = lvgl_runtime.runOnce(0);
                        }
                        continue;
                    }
                else
                    self.commands.recv() catch break;

                if (!first.ok) break;
                pending_render = try self.handleCommand(&lvgl_runtime, &render_state, first.value) or pending_render;

                var coalesced: u32 = 0;
                while (true) {
                    const next = self.commands.recvTimeout(0) catch break;
                    if (!next.ok) return;
                    pending_render = try self.handleCommand(&lvgl_runtime, &render_state, next.value) or pending_render;
                    coalesced += 1;
                }
                if (coalesced != 0) {
                    log.debug("ui commands coalesced requests={}", .{coalesced});
                }

                if (pending_render and canRender(last_render_at)) {
                    try self.renderOnce(&lvgl_runtime, &render_state, &last_render_at);
                    pending_render = false;
                }
                _ = lvgl_runtime.runOnce(0);
            }
            log.info("ui thread stopped", .{});
        }

        fn handleCommand(
            self: *Runtime,
            lvgl_runtime: *LvglRuntimeType,
            render_state: *RenderState,
            command: Command,
        ) !bool {
            _ = self;
            _ = render_state;
            switch (command) {
                .render => return true,
                .touch => |raw_touch| {
                    const raw_message: ZuxAppType.Message = .{
                        .origin = .source,
                        .timestamp = grt.time.instant.now(),
                        .body = .{ .raw_touch = raw_touch },
                    };
                    _ = try lvgl_runtime.reduce({}, raw_message, {});
                    return false;
                },
            }
        }

        fn renderOnce(
            self: *Runtime,
            lvgl_runtime: *LvglRuntimeType,
            render_state: *RenderState,
            last_render_at: *?glib.time.instant.Time,
        ) !void {
            self.render_seq +%= 1;
            const seq = self.render_seq;
            const started = grt.time.instant.now();
            last_render_at.* = started;
            log.debug("ui render begin seq={}", .{seq});
            try lvgl_runtime.render(&self.zux_app.impl);
            log.debug("ui render end seq={} elapsed_ms={}", .{
                seq,
                @divTrunc(grt.time.instant.sub(grt.time.instant.now(), started), glib.time.duration.MilliSecond),
            });
            render_state.updated = false;
        }

        fn render(render_state: *RenderState, runtime: *LvglRuntimeType, app: *Impl) !void {
            try ensureScreen(render_state, runtime, app);
            const player = app.store().stores.player.get();
            const playback = app.store().stores.playback.get();
            const audio_system = app.store().stores.audio.get();
            render_state.screen.?.setState(player, playback, audio_system);
            render_state.updated = true;
        }

        const RenderState = struct {
            screen: ?Screen = null,
            updated: bool = false,
        };

        fn ensureScreen(render_state: *RenderState, runtime: *LvglRuntimeType, app: *Impl) !void {
            if (render_state.screen != null) return;

            const display_state = app.store().stores.display.get();
            var display = app.display(.display);
            try display.setEnabled(display_state.enabled);
            try display.setBrightness(display_state.brightness);
            try runtime.ensureDisplay(display);
            render_state.screen = try Screen.init(runtime, runtime.displayHandle());
        }

        fn waitTimeout(pending_render: bool, last_render_at: ?glib.time.instant.Time) ?glib.time.duration.Duration {
            if (!pending_render) return consts.ui.poll_interval;
            const remaining = remainingRenderDelay(last_render_at);
            return if (remaining == 0) 0 else remaining;
        }

        fn canRender(last_render_at: ?glib.time.instant.Time) bool {
            return remainingRenderDelay(last_render_at) == 0;
        }

        fn remainingRenderDelay(last_render_at: ?glib.time.instant.Time) glib.time.duration.Duration {
            const last = last_render_at orelse return 0;
            const elapsed = grt.time.instant.sub(grt.time.instant.now(), last);
            if (elapsed >= render_interval) return 0;
            return render_interval - elapsed;
        }
    };
}

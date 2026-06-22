const glib = @import("glib");
const lvgl = @import("lvgl");

const ScreenMod = @import("Screen.zig");

pub fn make(comptime grt: type, comptime ZuxAppType: type) type {
    const Impl = ZuxAppType.ImplType;
    const LvglRuntimeType = lvgl.embed.LvglZuxRuntime.make(grt, Impl);
    const SceneState = @FieldType(ZuxAppType.Store.Stores, "scene").StateType;
    const Screen = ScreenMod.make(SceneState);
    const RenderResult = union(enum) {
        ok,
        err: anyerror,
    };
    const RenderCompletionChannel = grt.sync.Channel(RenderResult);
    const RenderCommand = struct {
        completion: ?*RenderCompletionChannel = null,
    };
    const Command = union(enum) {
        render: RenderCommand,
    };
    const CommandChannel = grt.sync.Channel(Command);
    const AtomicBool = grt.std.atomic.Value(bool);
    const log = grt.std.log.scoped(.colorbar_ui);

    return struct {
        const Runtime = @This();

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
                "zux/colorbar_adc/ui",
                self.config.task_options,
                glib.task.Routine.init(self, loop),
            );
            try self.requestRender();
        }

        pub fn requestRender(self: *Runtime) !void {
            if (!self.command_open) return;
            var completion = try RenderCompletionChannel.make(self.allocator, 1);
            defer completion.deinit();

            const result = try self.commands.sendTimeout(.{ .render = .{ .completion = &completion } }, 0);
            if (!result.ok) {
                log.warn("render request dropped: ui command queue full", .{});
                return;
            }

            const completed = try completion.recv();
            if (!completed.ok) return error.RuntimeClosed;
            switch (completed.value) {
                .ok => {},
                .err => |err| return err,
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

            var render_state: RenderState = .{};
            lvgl_runtime.setRenderFunc(&render_state, render);

            while (!self.stop.load(.acquire)) {
                const first = self.commands.recv() catch break;
                if (!first.ok) break;
                try self.handleCommand(&lvgl_runtime, &render_state, first.value);

                var coalesced: u32 = 0;
                while (true) {
                    const next = self.commands.recvTimeout(0) catch break;
                    if (!next.ok) return;
                    try self.handleCommand(&lvgl_runtime, &render_state, next.value);
                    coalesced += 1;
                }
                if (coalesced != 0) {
                    log.debug("ui render coalesced requests={}", .{coalesced});
                }
            }
            log.info("ui thread stopped", .{});
        }

        fn handleCommand(self: *Runtime, lvgl_runtime: *LvglRuntimeType, render_state: *RenderState, command: Command) !void {
            switch (command) {
                .render => |render_command| {
                    const result: anyerror!void = self.renderOnce(lvgl_runtime, render_state);
                    if (render_command.completion) |completion| {
                        result catch |err| {
                            _ = completion.send(.{ .err = err }) catch {};
                            return;
                        };
                        _ = completion.send(.ok) catch {};
                        return;
                    }
                    try result;
                },
            }
        }

        fn renderOnce(self: *Runtime, lvgl_runtime: *LvglRuntimeType, render_state: *RenderState) !void {
            render_state.state = self.zux_app.store.stores.scene.get();
            try lvgl_runtime.render(&self.zux_app.impl);
            render_state.state = null;
        }

        fn render(render_state: *RenderState, runtime: *LvglRuntimeType, app: *Impl) !void {
            try ensureScreen(render_state, runtime, app);
            const state = render_state.state orelse app.store().stores.scene.get();
            render_state.screen.?.setState(state);
        }

        const RenderState = struct {
            screen: ?Screen = null,
            state: ?SceneState = null,
        };

        fn ensureScreen(render_state: *RenderState, runtime: *LvglRuntimeType, app: *Impl) !void {
            if (render_state.screen != null) return;

            const display_state = app.store().stores.display.get();
            var display = app.display(.display);
            try display.setEnabled(display_state.enabled);
            try display.setBrightness(display_state.brightness);
            try runtime.ensureDisplay(display);
            render_state.screen = try Screen.init(runtime.displayHandle());
        }
    };
}

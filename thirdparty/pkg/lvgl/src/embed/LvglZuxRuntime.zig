const embed_pkg = @import("embed");
const glib = @import("glib");

const binding = @import("../binding.zig");
const Button = @import("../widget/Button.zig");
const Display = @import("../Display.zig");
const Event = @import("../Event.zig");
const Indev = @import("../Indev.zig");
const Point = @import("../Point.zig");
const LvglDisplay = @import("LvglDisplay.zig");

const Message = embed_pkg.zux.pipeline.Message;

pub const Config = struct {
    allocator: glib.std.mem.Allocator,
    threaded: bool = true,
    command_capacity: usize = 32,
    command_timeout: glib.time.duration.Duration = 1 * glib.time.duration.MilliSecond,
    rgb888_byte_order: LvglDisplay.Rgb888ByteOrder = .bgr,
};

pub fn make(comptime grt: type, comptime ZuxAppType: type) type {
    return struct {
        const LvglZuxRuntime = @This();
        const RawTouch = @FieldType(Message.Event, "raw_touch");
        const CommandChannel = grt.sync.Channel(Command);
        const RenderCompletionChannel = grt.sync.Channel(RenderResult);

        const RenderResult = union(enum) {
            ok,
            err: anyerror,
        };

        const RenderCommand = struct {
            app: *ZuxAppType,
            completion: ?*RenderCompletionChannel = null,
        };

        const Command = union(enum) {
            render: RenderCommand,
            touch: RawTouch,
        };

        const RenderHook = struct {
            ptr: *anyopaque,
            renderFn: *const fn (ptr: *anyopaque, runtime: *LvglZuxRuntime, app: *ZuxAppType) anyerror!void,

            fn init(pointer: anytype, comptime render_fn: anytype) RenderHook {
                const Ptr = @TypeOf(pointer);
                const info = @typeInfo(Ptr);
                if (info != .pointer or info.pointer.size != .one) {
                    @compileError("lvgl.embed.LvglZuxRuntime.setRenderFunc expects a single-item pointer");
                }

                const Impl = info.pointer.child;
                const gen = struct {
                    fn call(ptr: *anyopaque, runtime: *LvglZuxRuntime, app: *ZuxAppType) !void {
                        const self: *Impl = @ptrCast(@alignCast(ptr));
                        try render_fn(self, runtime, app);
                    }
                };

                return .{
                    .ptr = @ptrCast(pointer),
                    .renderFn = gen.call,
                };
            }

            fn render(self: RenderHook, runtime: *LvglZuxRuntime, app: *ZuxAppType) !void {
                try self.renderFn(self.ptr, runtime, app);
            }
        };

        const SingleButtonBinding = struct {
            pressed_dsc: ?*binding.EventDsc = null,
            released_dsc: ?*binding.EventDsc = null,
            runtime: *LvglZuxRuntime,
            label: ZuxAppType.PeriphLabel,
        };

        const GroupedButtonBinding = struct {
            pressed_dsc: ?*binding.EventDsc = null,
            released_dsc: ?*binding.EventDsc = null,
            runtime: *LvglZuxRuntime,
            label: ZuxAppType.PeriphLabel,
            button_id: u32,
        };

        allocator: glib.std.mem.Allocator = undefined,
        config: Config = undefined,
        commands: CommandChannel = undefined,
        command_open: bool = false,
        lvgl_display: LvglDisplay = .{},
        indev: ?Indev = null,
        draw_buffer: []u8 = &.{},
        flush_buffer: []embed_pkg.drivers.Display.Rgb = &.{},
        single_button_bindings: grt.std.ArrayList(*SingleButtonBinding) = .empty,
        grouped_button_bindings: grt.std.ArrayList(*GroupedButtonBinding) = .empty,
        state_mu: grt.std.Thread.Mutex = .{},
        zux_app: ?*ZuxAppType = null,
        render_hook: ?RenderHook = null,
        render_seq: u64 = 0,
        initialized: bool = false,
        owns_lvgl: bool = false,
        pressed: bool = false,
        last_point: Point = Point.init(0, 0),

        pub fn init(config: Config) !LvglZuxRuntime {
            var commands = try CommandChannel.make(config.allocator, config.command_capacity);
            errdefer commands.deinit();

            return .{
                .allocator = config.allocator,
                .config = config,
                .commands = commands,
                .command_open = true,
            };
        }

        pub fn deinit(self: *LvglZuxRuntime) void {
            self.close();
            self.deinitInput();
            self.lvgl_display.deinit();
            self.clearSingleButtonBindings();
            self.clearGroupedButtonBindings();
            if (self.draw_buffer.len != 0) {
                self.allocator.free(self.draw_buffer);
            }
            if (self.flush_buffer.len != 0) {
                self.allocator.free(self.flush_buffer);
            }
            if (self.owns_lvgl) {
                binding.lv_deinit();
            }
            self.commands.deinit();
            self.* = undefined;
        }

        pub fn setRenderFunc(self: *LvglZuxRuntime, pointer: anytype, comptime render_fn: anytype) void {
            self.render_hook = RenderHook.init(pointer, render_fn);
        }

        pub fn bindZuxApp(self: *LvglZuxRuntime, app: *ZuxAppType) void {
            self.zux_app = app;
        }

        pub fn render(self: *LvglZuxRuntime, app: *ZuxAppType) !void {
            if (self.config.threaded) {
                var completion = try RenderCompletionChannel.make(self.allocator, 1);
                defer completion.deinit();

                try self.sendCommand(.{ .render = .{
                    .app = app,
                    .completion = &completion,
                } });
                const result = try completion.recv();
                if (!result.ok) return error.RuntimeClosed;
                switch (result.value) {
                    .ok => {},
                    .err => |err| return err,
                }
                return;
            }

            try self.renderNow(app);
        }

        pub fn renderAsync(self: *LvglZuxRuntime, app: *ZuxAppType) !bool {
            if (self.config.threaded) {
                if (!self.command_open) return error.RuntimeClosed;
                const sent = try self.commands.sendTimeout(.{ .render = .{
                    .app = app,
                } }, 0);
                return sent.ok;
            }

            try self.renderNow(app);
            return true;
        }

        pub fn reduce(self: *LvglZuxRuntime, stores: anytype, message: Message, emit: anytype) !usize {
            _ = stores;
            _ = emit;

            switch (message.body) {
                .raw_touch => |raw_touch| {
                    if (self.config.threaded) {
                        try self.sendCommand(.{ .touch = raw_touch });
                    } else {
                        self.applyRawTouch(raw_touch);
                        self.dispatchTouch();
                    }
                },
                else => {},
            }
            return 0;
        }

        pub fn close(self: *LvglZuxRuntime) void {
            if (!self.command_open) return;
            self.command_open = false;
            self.commands.close();
        }

        pub fn runOnce(self: *LvglZuxRuntime, timeout: ?glib.time.duration.Duration) bool {
            if (!self.command_open) return false;

            const first = if (timeout) |duration|
                self.commands.recvTimeout(duration) catch |err| switch (err) {
                    error.Timeout => {
                        self.tick();
                        return true;
                    },
                    else => return false,
                }
            else
                self.commands.recv() catch return false;

            if (!first.ok) return false;
            self.handleCommand(first.value) catch {};
            while (true) {
                const next = self.commands.recvTimeout(0) catch break;
                if (!next.ok) return false;
                self.handleCommand(next.value) catch {};
            }
            self.tick();
            return true;
        }

        pub fn ensureDisplay(self: *LvglZuxRuntime, display: embed_pkg.drivers.Display) !void {
            if (self.initialized) {
                self.lvgl_display.setDisplay(display);
                return;
            }

            if (!binding.lv_is_initialized()) {
                binding.lv_init();
                self.owns_lvgl = true;
            }

            const flush_size = try display.maxFlushPixels();
            if (flush_size == 0) return error.InvalidDisplay;
            const draw_size = flush_size * 3;
            const draw_buffer = try self.allocator.alloc(u8, draw_size);
            errdefer self.allocator.free(draw_buffer);
            const flush_buffer = try self.allocator.alloc(embed_pkg.drivers.Display.Rgb, flush_size);
            errdefer self.allocator.free(flush_buffer);

            try self.lvgl_display.init(.{
                .display = display,
                .draw_buffer = draw_buffer,
                .flush_buffer = flush_buffer,
                .rgb888_byte_order = self.config.rgb888_byte_order,
            });
            errdefer self.lvgl_display.deinit();

            try self.initInput(self.lvgl_display.handle());
            self.draw_buffer = draw_buffer;
            self.flush_buffer = flush_buffer;
            self.initialized = true;
        }

        pub fn displayHandle(self: *LvglZuxRuntime) Display {
            return self.lvgl_display.handle();
        }

        pub fn displayRaw(self: *LvglZuxRuntime) *binding.Display {
            return self.lvgl_display.raw();
        }

        pub fn bindSingleButton(self: *LvglZuxRuntime, button: Button, label: ZuxAppType.PeriphLabel) !void {
            const binding_record = try self.allocator.create(SingleButtonBinding);
            errdefer self.allocator.destroy(binding_record);

            var obj = button.asObj();
            binding_record.* = .{
                .runtime = self,
                .label = label,
            };
            binding_record.pressed_dsc = obj.addEventCallbackRaw(buttonEventCb, Event.pressed, binding_record) orelse return error.OutOfMemory;
            errdefer if (binding_record.pressed_dsc) |descriptor| obj.removeEventDescriptor(descriptor);
            binding_record.released_dsc = obj.addEventCallbackRaw(buttonEventCb, Event.released, binding_record) orelse return error.OutOfMemory;
            errdefer if (binding_record.released_dsc) |descriptor| obj.removeEventDescriptor(descriptor);

            try self.single_button_bindings.append(self.allocator, binding_record);
        }

        pub fn bindGroupedButton(self: *LvglZuxRuntime, button: Button, label: ZuxAppType.PeriphLabel, button_id: u32) !void {
            const binding_record = try self.allocator.create(GroupedButtonBinding);
            errdefer self.allocator.destroy(binding_record);

            var obj = button.asObj();
            binding_record.* = .{
                .runtime = self,
                .label = label,
                .button_id = button_id,
            };
            binding_record.pressed_dsc = obj.addEventCallbackRaw(groupedButtonEventCb, Event.pressed, binding_record) orelse return error.OutOfMemory;
            errdefer if (binding_record.pressed_dsc) |descriptor| obj.removeEventDescriptor(descriptor);
            binding_record.released_dsc = obj.addEventCallbackRaw(groupedButtonEventCb, Event.released, binding_record) orelse return error.OutOfMemory;
            errdefer if (binding_record.released_dsc) |descriptor| obj.removeEventDescriptor(descriptor);

            try self.grouped_button_bindings.append(self.allocator, binding_record);
        }

        pub fn refresh(self: *LvglZuxRuntime) void {
            if (!self.initialized) return;
            binding.lv_refr_now(self.displayRaw());
        }

        fn sendCommand(self: *LvglZuxRuntime, command: Command) !void {
            if (!self.command_open) return error.RuntimeClosed;
            const sent = try self.commands.sendTimeout(command, self.config.command_timeout);
            if (!sent.ok) return error.RuntimeClosed;
        }

        fn handleCommand(self: *LvglZuxRuntime, command: Command) !void {
            switch (command) {
                .render => |completion| try self.handleRenderCommand(completion),
                .touch => |raw_touch| {
                    self.applyRawTouch(raw_touch);
                    self.dispatchTouch();
                },
            }
        }

        fn handleRenderCommand(self: *LvglZuxRuntime, command: RenderCommand) !void {
            const result: anyerror!void = self.renderNow(command.app);

            if (command.completion) |channel| {
                result catch |err| {
                    _ = channel.send(.{ .err = err }) catch {};
                    return;
                };
                _ = channel.send(.ok) catch {};
                return;
            }

            try result;
        }

        fn renderNow(self: *LvglZuxRuntime, app: *ZuxAppType) !void {
            const hook = self.render_hook orelse return error.MissingRenderFunc;
            self.render_seq += 1;
            try hook.render(self, app);
            self.refresh();
        }

        fn initInput(self: *LvglZuxRuntime, display: Display) !void {
            if (self.indev != null) return error.AlreadyInitialized;

            var indev = Indev.create() orelse return error.OutOfMemory;
            errdefer indev.delete();

            var target = display;
            indev.setDisplay(&target);
            indev.setType(.pointer);
            indev.setReadCb(readCb);
            indev.setUserData(self);

            self.indev = indev;
        }

        fn deinitInput(self: *LvglZuxRuntime) void {
            if (self.indev) |*indev| {
                indev.setUserData(null);
                indev.delete();
            }
            self.indev = null;
        }

        fn applyRawTouch(self: *LvglZuxRuntime, raw_touch: RawTouch) void {
            self.state_mu.lock();
            defer self.state_mu.unlock();

            self.pressed = raw_touch.pressed and raw_touch.point_count != 0;
            if (self.pressed) {
                self.last_point = Point.init(@intCast(raw_touch.x), @intCast(raw_touch.y));
            }
        }

        fn dispatchTouch(self: *LvglZuxRuntime) void {
            if (!self.initialized) return;
            if (self.indev) |*indev| {
                indev.read();
            }
            _ = binding.lv_timer_handler();
        }

        fn read(self: *LvglZuxRuntime, data: *binding.IndevData) void {
            self.state_mu.lock();
            const point_snapshot = self.last_point;
            const pressed_snapshot = self.pressed;
            self.state_mu.unlock();

            const state = if (pressed_snapshot) Indev.State.pressed else Indev.State.released;
            var indev_data = Indev.Data.fromRaw(data);
            indev_data.setPointer(@intCast(point_snapshot.x), @intCast(point_snapshot.y), state);
        }

        fn tick(self: *LvglZuxRuntime) void {
            if (!self.initialized) return;
            _ = binding.lv_timer_handler();
        }

        fn clearSingleButtonBindings(self: *LvglZuxRuntime) void {
            for (self.single_button_bindings.items) |binding_record| {
                self.allocator.destroy(binding_record);
            }
            self.single_button_bindings.deinit(self.allocator);
            self.single_button_bindings = .empty;
        }

        fn clearGroupedButtonBindings(self: *LvglZuxRuntime) void {
            for (self.grouped_button_bindings.items) |binding_record| {
                self.allocator.destroy(binding_record);
            }
            self.grouped_button_bindings.deinit(self.allocator);
            self.grouped_button_bindings = .empty;
        }

        fn emitSingleButton(self: *LvglZuxRuntime, label: ZuxAppType.PeriphLabel, pressed_value: bool) void {
            const app = self.zux_app orelse return;
            if (pressed_value) {
                app.press_single_button(label) catch {};
            } else {
                app.release_single_button(label) catch {};
            }
        }

        fn emitGroupedButton(self: *LvglZuxRuntime, label: ZuxAppType.PeriphLabel, button_id: u32, pressed_value: bool) void {
            const app = self.zux_app orelse return;
            if (pressed_value) {
                app.press_grouped_button(label, button_id) catch {};
            } else {
                app.release_grouped_button(label) catch {};
            }
        }

        fn readCb(indev: ?*binding.Indev, data: ?*binding.IndevData) callconv(.c) void {
            const out = data orelse return;
            const raw_indev = indev orelse return;
            const user_data = binding.lv_indev_get_user_data(raw_indev) orelse return;
            const self: *LvglZuxRuntime = @ptrCast(@alignCast(user_data));
            self.read(out);
        }

        fn buttonEventCb(event: ?*binding.Event) callconv(.c) void {
            const raw_event = event orelse return;
            var wrapped = Event.fromRaw(raw_event);
            const user_data = wrapped.userData() orelse return;
            const binding_record: *SingleButtonBinding = @ptrCast(@alignCast(user_data));
            const event_code = wrapped.code();
            if (event_code == Event.pressed) {
                binding_record.runtime.emitSingleButton(binding_record.label, true);
                return;
            }
            if (event_code == Event.released) {
                binding_record.runtime.emitSingleButton(binding_record.label, false);
            }
        }

        fn groupedButtonEventCb(event: ?*binding.Event) callconv(.c) void {
            const raw_event = event orelse return;
            var wrapped = Event.fromRaw(raw_event);
            const user_data = wrapped.userData() orelse return;
            const binding_record: *GroupedButtonBinding = @ptrCast(@alignCast(user_data));
            const event_code = wrapped.code();
            if (event_code == Event.pressed) {
                binding_record.runtime.emitGroupedButton(binding_record.label, binding_record.button_id, true);
                return;
            }
            if (event_code == Event.released) {
                binding_record.runtime.emitGroupedButton(binding_record.label, binding_record.button_id, false);
            }
        }
    };
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const DisplayApi = embed_pkg.drivers.Display;

    const TestCase = struct {
        const TestApp = struct {
            pub const PeriphLabel = enum { button, group };

            pressed_count: usize = 0,
            released_count: usize = 0,
            grouped_pressed_count: usize = 0,
            grouped_released_count: usize = 0,
            last_grouped_button_id: ?u32 = null,
            render_count: usize = 0,

            pub fn press_single_button(self: *@This(), label: PeriphLabel) !void {
                if (label == .button) self.pressed_count += 1;
            }

            pub fn release_single_button(self: *@This(), label: PeriphLabel) !void {
                if (label == .button) self.released_count += 1;
            }

            pub fn press_grouped_button(self: *@This(), label: PeriphLabel, button_id: u32) !void {
                if (label != .group) return;
                self.grouped_pressed_count += 1;
                self.last_grouped_button_id = button_id;
            }

            pub fn release_grouped_button(self: *@This(), label: PeriphLabel) !void {
                if (label != .group) return;
                self.grouped_released_count += 1;
            }
        };

        const Runtime = make(grt, TestApp);

        const DisplayBackend = struct {
            draws: usize = 0,

            fn deinitFn(_: *anyopaque) void {}

            fn widthFn(_: *anyopaque) u16 {
                return 4;
            }

            fn heightFn(_: *anyopaque) u16 {
                return 3;
            }

            fn maxFlushPixelsFn(_: *anyopaque) DisplayApi.Error!usize {
                return 4 * 3;
            }

            fn flushFn(
                ptr: *anyopaque,
                _: u16,
                _: u16,
                _: u16,
                _: u16,
                _: []const DisplayApi.Rgb,
            ) DisplayApi.Error!void {
                const backend: *@This() = @ptrCast(@alignCast(ptr));
                backend.draws += 1;
            }

            const vtable = DisplayApi.VTable{
                .deinit = deinitFn,
                .width = widthFn,
                .height = heightFn,
                .maxFlushPixels = maxFlushPixelsFn,
                .flush = flushFn,
            };

            fn api(self: *@This()) DisplayApi {
                return .{
                    .ptr = self,
                    .vtable = &vtable,
                };
            }
        };

        fn ensureDisplayCreatesRuntimeBuffers(_: *glib.testing.T, allocator: glib.std.mem.Allocator) !void {
            var backend = DisplayBackend{};
            var runtime = try Runtime.init(.{
                .allocator = allocator,
                .threaded = false,
            });
            defer runtime.deinit();

            try runtime.ensureDisplay(backend.api());

            try grt.std.testing.expect(runtime.initialized);
            try grt.std.testing.expect(runtime.indev != null);
            try grt.std.testing.expectEqual(@as(usize, 4 * 3 * 3), runtime.draw_buffer.len);
            try grt.std.testing.expectEqual(@as(usize, 4 * 3), runtime.flush_buffer.len);
        }

        fn reduceRawTouchUpdatesInputState(_: *glib.testing.T, allocator: glib.std.mem.Allocator) !void {
            var backend = DisplayBackend{};
            var runtime = try Runtime.init(.{
                .allocator = allocator,
                .threaded = false,
            });
            defer runtime.deinit();
            try runtime.ensureDisplay(backend.api());

            _ = try runtime.reduce({}, .{
                .origin = .source,
                .timestamp = 123,
                .body = .{
                    .raw_touch = .{
                        .source_id = 1,
                        .pressed = true,
                        .point_count = 1,
                        .x = 12,
                        .y = 34,
                    },
                },
            }, {});

            var data: binding.IndevData = undefined;
            runtime.read(&data);
            var indev_data = Indev.Data.fromRaw(&data);

            try grt.std.testing.expectEqual(@as(i32, 12), indev_data.pointX());
            try grt.std.testing.expectEqual(@as(i32, 34), indev_data.pointY());
            try grt.std.testing.expectEqual(Indev.State.pressed, indev_data.state());

            _ = try runtime.reduce({}, .{
                .origin = .source,
                .timestamp = 124,
                .body = .{
                    .raw_touch = .{
                        .source_id = 1,
                        .pressed = false,
                        .point_count = 0,
                    },
                },
            }, {});
            runtime.read(&data);

            try grt.std.testing.expectEqual(@as(i32, 12), indev_data.pointX());
            try grt.std.testing.expectEqual(@as(i32, 34), indev_data.pointY());
            try grt.std.testing.expectEqual(Indev.State.released, indev_data.state());
        }

        fn buttonEventsDispatchToBoundApp(_: *glib.testing.T, allocator: glib.std.mem.Allocator) !void {
            var backend = DisplayBackend{};
            var runtime = try Runtime.init(.{
                .allocator = allocator,
                .threaded = false,
            });
            defer runtime.deinit();
            try runtime.ensureDisplay(backend.api());

            var app = TestApp{};
            runtime.bindZuxApp(&app);

            var screen = runtime.displayHandle().activeScreen();
            var button = Button.create(&screen) orelse return error.OutOfMemory;
            var button_obj = button.asObj();
            button_obj.setPos(10, 10);
            button_obj.setSize(80, 40);
            button_obj.updateLayout();

            try runtime.bindSingleButton(button, .button);
            _ = button_obj.sendEvent(Event.pressed, null);
            _ = button_obj.sendEvent(Event.released, null);

            try grt.std.testing.expectEqual(@as(usize, 1), app.pressed_count);
            try grt.std.testing.expectEqual(@as(usize, 1), app.released_count);
        }

        fn groupedButtonEventsDispatchToBoundApp(_: *glib.testing.T, allocator: glib.std.mem.Allocator) !void {
            var backend = DisplayBackend{};
            var runtime = try Runtime.init(.{
                .allocator = allocator,
                .threaded = false,
            });
            defer runtime.deinit();
            try runtime.ensureDisplay(backend.api());

            var app = TestApp{};
            runtime.bindZuxApp(&app);

            var screen = runtime.displayHandle().activeScreen();
            var button = Button.create(&screen) orelse return error.OutOfMemory;
            var button_obj = button.asObj();
            button_obj.setPos(10, 10);
            button_obj.setSize(80, 40);
            button_obj.updateLayout();

            try runtime.bindGroupedButton(button, .group, 3);
            _ = button_obj.sendEvent(Event.pressed, null);
            _ = button_obj.sendEvent(Event.released, null);

            try grt.std.testing.expectEqual(@as(usize, 1), app.grouped_pressed_count);
            try grt.std.testing.expectEqual(@as(usize, 1), app.grouped_released_count);
            try grt.std.testing.expectEqual(@as(?u32, 3), app.last_grouped_button_id);
        }

        fn renderCallsHookAndTracksSequence(_: *glib.testing.T, allocator: glib.std.mem.Allocator) !void {
            const Hook = struct {
                calls: usize = 0,

                fn render(self: *@This(), _: *Runtime, app: *TestApp) !void {
                    self.calls += 1;
                    app.render_count += 1;
                }
            };

            var app = TestApp{};
            var hook = Hook{};
            var runtime = try Runtime.init(.{
                .allocator = allocator,
                .threaded = false,
            });
            defer runtime.deinit();

            runtime.setRenderFunc(&hook, Hook.render);
            try runtime.render(&app);

            try grt.std.testing.expectEqual(@as(usize, 1), hook.calls);
            try grt.std.testing.expectEqual(@as(usize, 1), app.render_count);
            try grt.std.testing.expectEqual(@as(u64, 1), runtime.render_seq);
        }

        fn threadedRenderUsesRenderArgument(_: *glib.testing.T, allocator: glib.std.mem.Allocator) !void {
            const Hook = struct {
                fn render(_: *@This(), _: *Runtime, app: *TestApp) !void {
                    app.render_count += 1;
                }
            };

            var app = TestApp{};
            var hook = Hook{};
            var runtime = try Runtime.init(.{
                .allocator = allocator,
                .threaded = true,
            });
            defer runtime.deinit();
            runtime.setRenderFunc(&hook, Hook.render);

            const worker = try grt.std.Thread.spawn(.{}, struct {
                fn run(rt: *Runtime) void {
                    _ = rt.runOnce(null);
                }
            }.run, .{&runtime});
            defer worker.join();

            try runtime.render(&app);

            try grt.std.testing.expectEqual(@as(usize, 1), app.render_count);
            try grt.std.testing.expectEqual(@as(u64, 1), runtime.render_seq);
        }

        fn threadedRenderAsyncQueuesWithoutWaiting(_: *glib.testing.T, allocator: glib.std.mem.Allocator) !void {
            const Hook = struct {
                fn render(_: *@This(), _: *Runtime, app: *TestApp) !void {
                    app.render_count += 1;
                }
            };

            var app = TestApp{};
            var hook = Hook{};
            var runtime = try Runtime.init(.{
                .allocator = allocator,
                .threaded = true,
            });
            defer runtime.deinit();
            runtime.setRenderFunc(&hook, Hook.render);

            try grt.std.testing.expect(try runtime.renderAsync(&app));
            try grt.std.testing.expectEqual(@as(usize, 0), app.render_count);
            try grt.std.testing.expect(runtime.runOnce(null));

            try grt.std.testing.expectEqual(@as(usize, 1), app.render_count);
            try grt.std.testing.expectEqual(@as(u64, 1), runtime.render_seq);
        }

        fn threadedRenderReportsFullCommandQueue(_: *glib.testing.T, allocator: glib.std.mem.Allocator) !void {
            var app = TestApp{};
            var runtime = try Runtime.init(.{
                .allocator = allocator,
                .threaded = true,
                .command_capacity = 1,
                .command_timeout = 0,
            });
            defer runtime.deinit();

            _ = try runtime.reduce({}, .{
                .origin = .source,
                .timestamp = 123,
                .body = .{
                    .raw_touch = .{
                        .source_id = 1,
                        .pressed = true,
                        .point_count = 1,
                        .x = 12,
                        .y = 34,
                    },
                },
            }, {});

            try grt.std.testing.expectError(error.Timeout, runtime.render(&app));
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;

            t.run(
                "lvgl/unit_tests/embed.LvglZuxRuntime/ensure_display_creates_runtime_buffers",
                glib.testing.TestRunner.fromFn(grt.std, 1024 * 1024, TestCase.ensureDisplayCreatesRuntimeBuffers),
            );
            t.run(
                "lvgl/unit_tests/embed.LvglZuxRuntime/reduce_raw_touch_updates_input_state",
                glib.testing.TestRunner.fromFn(grt.std, 1024 * 1024, TestCase.reduceRawTouchUpdatesInputState),
            );
            t.run(
                "lvgl/unit_tests/embed.LvglZuxRuntime/button_events_dispatch_to_bound_app",
                glib.testing.TestRunner.fromFn(grt.std, 1024 * 1024, TestCase.buttonEventsDispatchToBoundApp),
            );
            t.run(
                "lvgl/unit_tests/embed.LvglZuxRuntime/grouped_button_events_dispatch_to_bound_app",
                glib.testing.TestRunner.fromFn(grt.std, 1024 * 1024, TestCase.groupedButtonEventsDispatchToBoundApp),
            );
            t.run(
                "lvgl/unit_tests/embed.LvglZuxRuntime/render_calls_hook_and_tracks_sequence",
                glib.testing.TestRunner.fromFn(grt.std, 1024 * 1024, TestCase.renderCallsHookAndTracksSequence),
            );
            t.run(
                "lvgl/unit_tests/embed.LvglZuxRuntime/threaded_render_uses_render_argument",
                glib.testing.TestRunner.fromFn(grt.std, 1024 * 1024, TestCase.threadedRenderUsesRenderArgument),
            );
            t.run(
                "lvgl/unit_tests/embed.LvglZuxRuntime/threaded_render_async_queues_without_waiting",
                glib.testing.TestRunner.fromFn(grt.std, 1024 * 1024, TestCase.threadedRenderAsyncQueuesWithoutWaiting),
            );
            t.run(
                "lvgl/unit_tests/embed.LvglZuxRuntime/threaded_render_reports_full_command_queue",
                glib.testing.TestRunner.fromFn(grt.std, 1024 * 1024, TestCase.threadedRenderReportsFullCommandQueue),
            );
            _ = allocator;
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

const stdz = @import("stdz");
const drivers = @import("drivers");
const ledstrip = @import("ledstrip");
const testing_api = @import("testing");
const sync = @import("sync");

const Assembler = @import("Assembler.zig");
const Store = @import("Store.zig");
const AssemblerConfig = @import("assembler/Config.zig");
const ComponentSpec = @import("spec/Component.zig");
const Doc = @import("spec/Doc.zig");
const ReducerSpec = @import("spec/Reducer.zig");
const RenderSpec = @import("spec/Render.zig");
const StatePathSpec = @import("spec/StatePath.zig");
const StoreObjectSpecType = @import("spec/StoreObject.zig");
const UserStorySpec = @import("spec/UserStory.zig");
const JsonParser = @import("spec/JsonParser.zig");
const StoreObjectSpec = type;

const Spec = @This();

pub const ParsedSpec = union(enum) {
    store: StoreObjectSpec,
    state_path: StatePathSpec,
    component: ComponentSpec,
    reducer: ReducerSpec,
    render: RenderSpec,
    user_story: UserStorySpec,
    doc: Doc,
};

pub fn parseSlice(comptime source: []const u8) ParsedSpec {
    comptime {
        @setEvalBranchQuota(40_000);
    }

    var parser = JsonParser.init(source);
    parser.expectByte('{');

    var kind: ?[]const u8 = null;
    var spec_source: ?[]const u8 = null;

    if (parser.consumeByte('}')) {
        @compileError("zux.Spec.parseSlice requires `kind` and `spec` fields");
    }

    while (true) {
        const key = parser.parseString();
        parser.expectByte(':');

        if (comptimeEql(key, "kind")) {
            if (kind != null) {
                @compileError("zux.Spec.parseSlice contains duplicate `kind` field");
            }
            kind = parser.parseString();
        } else if (comptimeEql(key, "spec")) {
            if (spec_source != null) {
                @compileError("zux.Spec.parseSlice contains duplicate `spec` field");
            }
            spec_source = parser.parseValueSlice();
        } else {
            _ = parser.parseValueSlice();
            @compileError("zux.Spec.parseSlice only supports `kind` and `spec` fields");
        }

        if (parser.consumeByte(',')) continue;
        parser.expectByte('}');
        break;
    }
    parser.finish();

    const kind_value = kind orelse @compileError("zux.Spec.parseSlice requires a `kind` field");
    const spec_value = spec_source orelse @compileError("zux.Spec.parseSlice requires a `spec` field");

    if (comptimeEql(kind_value, "Store")) {
        return .{ .store = StoreObjectSpecType.parseSlice(spec_value) };
    }
    if (comptimeEql(kind_value, "StatePath")) {
        return .{ .state_path = StatePathSpec.parseSlice(spec_value) };
    }
    if (componentKindPath(kind_value)) |kind_path| {
        return .{ .component = ComponentSpec.parseSliceWithKindPath(kind_path, spec_value) };
    }
    if (comptimeEql(kind_value, "Reducer")) {
        return .{ .reducer = ReducerSpec.parseSlice(spec_value) };
    }
    if (comptimeEql(kind_value, "Render")) {
        return .{ .render = RenderSpec.parseSlice(spec_value) };
    }
    if (comptimeEql(kind_value, "UserStory")) {
        return .{ .user_story = UserStorySpec.parseSlice(spec_value) };
    }
    if (comptimeEql(kind_value, "Doc")) {
        return .{ .doc = parseDocSpecSlice(spec_value) };
    }

    @compileError("zux.Spec.parseSlice encountered an unknown `kind` value");
}

fn parseDocSpecSlice(comptime source: []const u8) Doc {
    comptime {
        @setEvalBranchQuota(100_000);
    }

    var next: Doc = .{};
    var parser = JsonParser.init(source);
    parser.expectByte('[');

    if (!parser.consumeByte(']')) {
        while (true) {
            next.addParsed(parseSlice(parser.parseValueSlice()));

            if (parser.consumeByte(',')) continue;
            parser.expectByte(']');
            break;
        }
    }
    parser.finish();

    return next;
}

fn componentKindPath(comptime kind_value: []const u8) ?[]const u8 {
    if (comptimeEql(kind_value, "Component")) return "";
    if (comptimeStartsWith(kind_value, "Component/")) {
        return kind_value["Component/".len..];
    }
    return null;
}

pub fn make(comptime spec_doc: anytype) type {
    const SpecDocType = @TypeOf(spec_doc);
    const stores_doc = if (@hasField(SpecDocType, "stores")) spec_doc.stores else &.{};
    const state_paths_doc = if (@hasField(SpecDocType, "state_paths")) spec_doc.state_paths else &.{};
    const components_doc = if (@hasField(SpecDocType, "components")) spec_doc.components else &.{};
    const reducers_doc = if (@hasField(SpecDocType, "reducers")) spec_doc.reducers else &.{};
    const renders_doc = if (@hasField(SpecDocType, "renders")) spec_doc.renders else &.{};
    const user_stories_doc = if (@hasField(SpecDocType, "user_stories")) spec_doc.user_stories else &.{};
    const component_count = components_doc.len;
    const reducer_count = reducers_doc.len;
    const render_count = renders_doc.len;

    return struct {
        const Self = @This();

        flow_hooks: [component_count]?Assembler.FlowTypeFactory =
            [_]?Assembler.FlowTypeFactory{null} ** component_count,
        reducer_hooks: [reducer_count]?Assembler.ReducerFnFactory =
            [_]?Assembler.ReducerFnFactory{null} ** reducer_count,
        render_hooks: [render_count]?Assembler.RenderFnFactory =
            [_]?Assembler.RenderFnFactory{null} ** render_count,

        pub const stores = stores_doc;
        pub const state_paths = state_paths_doc;
        pub const components = components_doc;
        pub const reducers = reducers_doc;
        pub const renders = renders_doc;
        pub const user_stories = user_stories_doc;

        pub fn init() Self {
            return .{};
        }

        pub fn setReducer(
            self: *Self,
            comptime label: []const u8,
            comptime factory: Assembler.ReducerFnFactory,
        ) void {
            const idx = reducerIndex(label);
            self.reducer_hooks[idx] = factory;
        }

        pub fn setFlow(
            self: *Self,
            comptime label: []const u8,
            comptime FlowType: type,
        ) void {
            const idx = flowIndex(label);
            self.flow_hooks[idx] = makeFlowTypeFactory(FlowType);
        }

        pub fn setRender(
            self: *Self,
            comptime label: []const u8,
            comptime factory: Assembler.RenderFnFactory,
        ) void {
            const idx = renderIndex(label);
            self.render_hooks[idx] = factory;
        }

        pub fn assembler(
            self: *Self,
            comptime lib: type,
            comptime config: AssemblerConfig,
            comptime Channel: fn (type) type,
        ) Assembler.make(lib, config, Channel) {
            const AssemblerType = Assembler.make(lib, config, Channel);

            return comptime blk: {
                var next = AssemblerType.init();

                for (stores) |store_spec| {
                    next.setStore(
                        store_spec.Label,
                        Store.Object.make(
                            lib,
                            store_spec.StateType,
                            store_spec.Label,
                        ),
                    );
                }

                for (state_paths) |state_path| {
                    next.setState(state_path.path, state_path.labels);
                }

                for (components) |component| {
                    const label = component.label;
                    switch (component.kind) {
                        .grouped_button => |grouped_button| {
                            next.addGroupedButton(label, component.id, grouped_button.button_count);
                        },
                        .single_button => {
                            next.addSingleButton(label, component.id);
                        },
                        .imu => {
                            next.addImu(label, component.id);
                        },
                        .led_strip => |led_strip| {
                            next.addLedStrip(label, component.id, led_strip.pixel_count);
                        },
                        .modem => {
                            next.addModem(label, component.id);
                        },
                        .nfc => {
                            next.addNfc(label, component.id);
                        },
                        .wifi_sta => {
                            next.addWifiSta(label, component.id);
                        },
                        .wifi_ap => {
                            next.addWifiAp(label, component.id);
                        },
                        .router => |router_component| {
                            next.addRouter(label, component.id, router_component.initial_item);
                        },
                        .flow => |flow_component| {
                            const flow_factory = self.flow_hooks[componentIndex(label)] orelse
                                @compileError(
                                    "zux.Spec.assembler missing flow implementation for label '" ++
                                        label ++
                                        "' (flow type_name '" ++
                                        flow_component.type_name ++
                                        "'); call spec.setFlow(\"" ++ label ++ "\", ...)",
                                );
                            next.addFlow(label, component.id, flow_factory());
                        },
                        .overlay => |overlay_component| {
                            next.addOverlay(label, component.id, overlay_component.initial_state);
                        },
                        .selection => |selection_component| {
                            next.addSelection(label, component.id, selection_component.initial_state);
                        },
                    }
                }

                for (reducers, 0..) |reducer_spec, i| {
                    const reducer_factory = self.reducer_hooks[i] orelse
                        @compileError(
                            "zux.Spec.assembler missing reducer implementation for label '" ++
                                reducer_spec.label ++
                                "' (reducer_fn_name '" ++
                                reducer_spec.reducer_fn_name ++
                                "'); call spec.setReducer(\"" ++ reducer_spec.label ++ "\", ...)",
                        );
                    next.addReducer(
                        reducer_spec.label,
                        reducer_factory,
                    );
                }

                for (renders, 0..) |render_spec, i| {
                    const render_factory = self.render_hooks[i] orelse
                        @compileError(
                            "zux.Spec.assembler missing render implementation for label '" ++
                                render_spec.label ++
                                "' (render_fn_name '" ++
                                render_spec.render_fn_name ++
                                "'); call spec.setRender(\"" ++ render_spec.label ++ "\", ...)",
                        );
                    next.addRender(render_spec.state_path, render_factory);
                }

                break :blk next;
            };
        }

        pub fn testRunner(
            self: *Self,
            comptime lib: type,
            comptime config: AssemblerConfig,
            comptime Channel: fn (type) type,
        ) testing_api.TestRunner {
            const BuiltApp = comptime blk: {
                const assembled = self.assembler(lib, config, Channel);
                break :blk assembled.build(makeTestBuildConfig(assembled.BuildConfig()));
            };

            const Runner = struct {
                pub fn init(self_runner: *@This(), allocator: lib.mem.Allocator) !void {
                    _ = self_runner;
                    _ = allocator;
                }

                pub fn run(self_runner: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
                    _ = self_runner;

                    inline for (user_stories) |story| {
                        var app = BuiltApp.init(makeTestInitConfig(lib, BuiltApp, allocator)) catch |err| {
                            t.logFatal(@errorName(err));
                            return false;
                        };
                        defer app.deinit();

                        t.run(story.name, story.createTestRunner(BuiltApp, &app));
                        if (!t.wait()) return false;
                    }

                    return true;
                }

                pub fn deinit(self_runner: *@This(), allocator: lib.mem.Allocator) void {
                    _ = self_runner;
                    _ = allocator;
                }
            };

            const Holder = struct {
                var runner: Runner = .{};
            };
            return testing_api.TestRunner.make(Runner).new(&Holder.runner);
        }

        fn reducerIndex(comptime label: []const u8) usize {
            inline for (reducers, 0..) |reducer, i| {
                if (stdz.mem.eql(u8, reducer.label, label)) return i;
            }

            @compileError("zux.Spec.setReducer received a label '" ++ label ++ "' that is not declared in the spec doc reducer list");
        }

        fn componentIndex(comptime label: []const u8) usize {
            inline for (components, 0..) |component, i| {
                if (stdz.mem.eql(u8, component.label, label)) return i;
            }

            @compileError("zux.Spec received a component label '" ++ label ++ "' that is not declared in the spec doc component list");
        }

        fn flowIndex(comptime label: []const u8) usize {
            const idx = componentIndex(label);
            switch (components[idx].kind) {
                .flow => return idx,
                else => @compileError("zux.Spec.setFlow received a label '" ++ label ++ "' that is not declared as a flow component"),
            }
        }

        fn renderIndex(comptime label: []const u8) usize {
            inline for (renders, 0..) |render_spec, i| {
                if (stdz.mem.eql(u8, render_spec.label, label)) return i;
            }

            @compileError("zux.Spec.setRender received a label '" ++ label ++ "' that is not declared in the spec doc render list");
        }

        fn makeFlowTypeFactory(comptime FlowType: type) Assembler.FlowTypeFactory {
            return struct {
                fn factory() type {
                    return FlowType;
                }
            }.factory;
        }

        fn makeTestBuildConfig(comptime BuildConfig: type) BuildConfig {
            var build_config: BuildConfig = undefined;

            inline for (@typeInfo(BuildConfig).@"struct".fields) |field| {
                @field(build_config, field.name) = componentControlType(field.name);
            }

            return build_config;
        }

        fn makeTestInitConfig(
            comptime lib: type,
            comptime AppType: type,
            allocator: lib.mem.Allocator,
        ) AppType.InitConfig {
            var init_config: AppType.InitConfig = undefined;

            inline for (@typeInfo(AppType.InitConfig).@"struct".fields) |field| {
                if (comptime comptimeEql(field.name, "allocator")) {
                    @field(init_config, field.name) = allocator;
                } else if (comptime comptimeEql(field.name, "user_root_config")) {
                    @field(init_config, field.name) = .{};
                } else {
                    @field(init_config, field.name) = makeTestPeriphValue(field.name, field.type);
                }
            }

            return init_config;
        }

        fn componentControlType(comptime label: []const u8) type {
            const component = componentForLabel(label);
            return switch (component.kind) {
                .single_button => drivers.button.Single,
                .grouped_button => drivers.button.Grouped,
                .imu => drivers.imu,
                .led_strip => ledstrip.LedStrip,
                .modem => drivers.Modem,
                .nfc => drivers.nfc.Reader,
                .wifi_sta => drivers.wifi.Sta,
                .wifi_ap => drivers.wifi.Ap,
                else => @compileError(
                    "zux.Spec.testRunner cannot synthesize a test control for component '" ++
                        label ++
                        "'",
                ),
            };
        }

        fn componentForLabel(comptime label: []const u8) ComponentSpec {
            inline for (components) |component| {
                if (stdz.mem.eql(u8, component.label, label)) return component;
            }

            @compileError("zux.Spec.testRunner could not find component label '" ++ label ++ "'");
        }

        fn makeTestPeriphValue(comptime label: []const u8, comptime PeriphType: type) PeriphType {
            if (PeriphType == drivers.button.Single) {
                return makeTestSingleButton();
            }
            if (PeriphType == drivers.button.Grouped) {
                return makeTestGroupedButton();
            }
            if (PeriphType == drivers.imu) {
                return makeTestImu();
            }
            if (PeriphType == ledstrip.LedStrip) {
                return makeTestLedStrip(label, ledStripPixelCount(label));
            }
            if (PeriphType == drivers.Modem) {
                return makeTestModem();
            }
            if (PeriphType == drivers.nfc.Reader) {
                return makeTestNfcReader();
            }
            if (PeriphType == drivers.wifi.Sta) {
                return makeTestWifiSta();
            }
            if (PeriphType == drivers.wifi.Ap) {
                return makeTestWifiAp();
            }

            @compileError("zux.Spec.testRunner does not know how to initialize a test periph for this field type");
        }

        fn ledStripPixelCount(comptime label: []const u8) usize {
            return switch (componentForLabel(label).kind) {
                .led_strip => |component| component.pixel_count,
                else => @compileError(
                    "zux.Spec.testRunner expected led_strip component metadata for label '" ++
                        label ++
                        "'",
                ),
            };
        }

        fn makeTestSingleButton() drivers.button.Single {
            const Impl = struct {
                pub fn isPressed(_: *@This()) !bool {
                    return false;
                }
            };
            const Holder = struct {
                var impl = Impl{};
            };
            return drivers.button.Single.init(Impl, &Holder.impl);
        }

        fn makeTestGroupedButton() drivers.button.Grouped {
            const Impl = struct {
                pub fn pressedButtonId(_: *@This()) !?u32 {
                    return null;
                }
            };
            const Holder = struct {
                var impl = Impl{};
            };
            return drivers.button.Grouped.init(Impl, &Holder.impl);
        }

        fn makeTestImu() drivers.imu {
            const Impl = struct {
                pub fn read(_: *@This()) !drivers.imu.Sample {
                    return .{};
                }
            };
            const Holder = struct {
                var impl = Impl{};
            };
            return drivers.imu.init(&Holder.impl);
        }

        fn makeTestLedStrip(comptime label: []const u8, comptime pixel_count: usize) ledstrip.LedStrip {
            _ = label;
            const Impl = struct {
                pixels: [pixel_count]ledstrip.Color = [_]ledstrip.Color{ledstrip.Color.black} ** pixel_count,

                pub fn deinit(_: *@This()) void {}

                pub fn count(_: *@This()) usize {
                    return pixel_count;
                }

                pub fn setPixel(self: *@This(), index: usize, color: ledstrip.Color) void {
                    if (index >= self.pixels.len) return;
                    self.pixels[index] = color;
                }

                pub fn pixel(self: *@This(), index: usize) ledstrip.Color {
                    if (index >= self.pixels.len) return ledstrip.Color.black;
                    return self.pixels[index];
                }

                pub fn refresh(_: *@This()) void {}
            };
            const Holder = struct {
                var impl = Impl{};
            };
            const VTableGen = struct {
                fn deinitFn(ptr: *anyopaque) void {
                    const impl: *Impl = @ptrCast(@alignCast(ptr));
                    impl.deinit();
                }

                fn countFn(ptr: *anyopaque) usize {
                    const impl: *Impl = @ptrCast(@alignCast(ptr));
                    return impl.count();
                }

                fn setPixelFn(ptr: *anyopaque, index: usize, color: ledstrip.Color) void {
                    const impl: *Impl = @ptrCast(@alignCast(ptr));
                    impl.setPixel(index, color);
                }

                fn pixelFn(ptr: *anyopaque, index: usize) ledstrip.Color {
                    const impl: *Impl = @ptrCast(@alignCast(ptr));
                    return impl.pixel(index);
                }

                fn refreshFn(ptr: *anyopaque) void {
                    const impl: *Impl = @ptrCast(@alignCast(ptr));
                    impl.refresh();
                }

                const vtable = ledstrip.LedStrip.VTable{
                    .deinit = deinitFn,
                    .count = countFn,
                    .setPixel = setPixelFn,
                    .pixel = pixelFn,
                    .refresh = refreshFn,
                };
            };

            return .{
                .ptr = @ptrCast(&Holder.impl),
                .vtable = &VTableGen.vtable,
            };
        }

        fn makeTestModem() drivers.Modem {
            const Impl = struct {
                pub fn deinit(_: *@This()) void {}

                pub fn state(_: *@This()) drivers.Modem.State {
                    return .{};
                }

                pub fn imei(_: *@This()) ?[]const u8 {
                    return null;
                }

                pub fn imsi(_: *@This()) ?[]const u8 {
                    return null;
                }

                pub fn apn(_: *@This()) ?[]const u8 {
                    return null;
                }

                pub fn setApn(_: *@This(), _: []const u8) drivers.Modem.SetApnError!void {}

                pub fn dataOpen(_: *@This()) drivers.Modem.DataOpenError!void {
                    return error.Unsupported;
                }

                pub fn dataClose(_: *@This()) void {}

                pub fn dataRead(_: *@This(), _: []u8) drivers.Modem.DataReadError!usize {
                    return error.Unsupported;
                }

                pub fn dataWrite(_: *@This(), _: []const u8) drivers.Modem.DataWriteError!usize {
                    return error.Unsupported;
                }

                pub fn dataState(_: *@This()) drivers.Modem.DataState {
                    return .closed;
                }

                pub fn setDataReadTimeout(_: *@This(), _: ?u32) void {}

                pub fn setDataWriteTimeout(_: *@This(), _: ?u32) void {}

                pub fn setEventCallback(_: *@This(), _: *const anyopaque, _: drivers.Modem.CallbackFn) void {}

                pub fn clearEventCallback(_: *@This()) void {}
            };
            const Holder = struct {
                var impl = Impl{};
            };
            const VTableGen = struct {
                fn deinitFn(ptr: *anyopaque) void {
                    const impl: *Impl = @ptrCast(@alignCast(ptr));
                    impl.deinit();
                }

                fn stateFn(ptr: *anyopaque) drivers.Modem.State {
                    const impl: *Impl = @ptrCast(@alignCast(ptr));
                    return impl.state();
                }

                fn imeiFn(ptr: *anyopaque) ?[]const u8 {
                    const impl: *Impl = @ptrCast(@alignCast(ptr));
                    return impl.imei();
                }

                fn imsiFn(ptr: *anyopaque) ?[]const u8 {
                    const impl: *Impl = @ptrCast(@alignCast(ptr));
                    return impl.imsi();
                }

                fn apnFn(ptr: *anyopaque) ?[]const u8 {
                    const impl: *Impl = @ptrCast(@alignCast(ptr));
                    return impl.apn();
                }

                fn setApnFn(ptr: *anyopaque, value: []const u8) drivers.Modem.SetApnError!void {
                    const impl: *Impl = @ptrCast(@alignCast(ptr));
                    return impl.setApn(value);
                }

                fn dataOpenFn(ptr: *anyopaque) drivers.Modem.DataOpenError!void {
                    const impl: *Impl = @ptrCast(@alignCast(ptr));
                    return impl.dataOpen();
                }

                fn dataCloseFn(ptr: *anyopaque) void {
                    const impl: *Impl = @ptrCast(@alignCast(ptr));
                    impl.dataClose();
                }

                fn dataReadFn(ptr: *anyopaque, buf: []u8) drivers.Modem.DataReadError!usize {
                    const impl: *Impl = @ptrCast(@alignCast(ptr));
                    return impl.dataRead(buf);
                }

                fn dataWriteFn(ptr: *anyopaque, buf: []const u8) drivers.Modem.DataWriteError!usize {
                    const impl: *Impl = @ptrCast(@alignCast(ptr));
                    return impl.dataWrite(buf);
                }

                fn dataStateFn(ptr: *anyopaque) drivers.Modem.DataState {
                    const impl: *Impl = @ptrCast(@alignCast(ptr));
                    return impl.dataState();
                }

                fn setDataReadTimeoutFn(ptr: *anyopaque, ms: ?u32) void {
                    const impl: *Impl = @ptrCast(@alignCast(ptr));
                    impl.setDataReadTimeout(ms);
                }

                fn setDataWriteTimeoutFn(ptr: *anyopaque, ms: ?u32) void {
                    const impl: *Impl = @ptrCast(@alignCast(ptr));
                    impl.setDataWriteTimeout(ms);
                }

                fn setEventCallbackFn(ptr: *anyopaque, ctx: *const anyopaque, emit_fn: drivers.Modem.CallbackFn) void {
                    const impl: *Impl = @ptrCast(@alignCast(ptr));
                    impl.setEventCallback(ctx, emit_fn);
                }

                fn clearEventCallbackFn(ptr: *anyopaque) void {
                    const impl: *Impl = @ptrCast(@alignCast(ptr));
                    impl.clearEventCallback();
                }

                const vtable = drivers.Modem.VTable{
                    .deinit = deinitFn,
                    .state = stateFn,
                    .imei = imeiFn,
                    .imsi = imsiFn,
                    .apn = apnFn,
                    .setApn = setApnFn,
                    .dataOpen = dataOpenFn,
                    .dataClose = dataCloseFn,
                    .dataRead = dataReadFn,
                    .dataWrite = dataWriteFn,
                    .dataState = dataStateFn,
                    .setDataReadTimeout = setDataReadTimeoutFn,
                    .setDataWriteTimeout = setDataWriteTimeoutFn,
                    .setEventCallback = setEventCallbackFn,
                    .clearEventCallback = clearEventCallbackFn,
                };
            };

            return .{
                .ptr = @ptrCast(&Holder.impl),
                .vtable = &VTableGen.vtable,
            };
        }

        fn makeTestNfcReader() drivers.nfc.Reader {
            const Impl = struct {
                pub fn setEventCallback(_: *@This(), _: *const anyopaque, _: drivers.nfc.CallbackFn) void {}

                pub fn clearEventCallback(_: *@This()) void {}
            };
            const Holder = struct {
                var impl = Impl{};
            };
            return drivers.nfc.Reader.init(&Holder.impl);
        }

        fn makeTestWifiSta() drivers.wifi.Sta {
            const Impl = struct {
                pub fn startScan(_: *@This(), _: drivers.wifi.Sta.ScanConfig) drivers.wifi.Sta.ScanError!void {}

                pub fn stopScan(_: *@This()) void {}

                pub fn connect(_: *@This(), _: drivers.wifi.Sta.ConnectConfig) drivers.wifi.Sta.ConnectError!void {}

                pub fn disconnect(_: *@This()) void {}

                pub fn getState(_: *@This()) drivers.wifi.Sta.State {
                    return .idle;
                }

                pub fn addEventHook(_: *@This(), _: ?*anyopaque, _: *const fn (?*anyopaque, drivers.wifi.Sta.Event) void) void {}

                pub fn removeEventHook(_: *@This(), _: ?*anyopaque, _: *const fn (?*anyopaque, drivers.wifi.Sta.Event) void) void {}

                pub fn getMacAddr(_: *@This()) ?drivers.wifi.Sta.MacAddr {
                    return null;
                }

                pub fn getIpInfo(_: *@This()) ?drivers.wifi.Sta.IpInfo {
                    return null;
                }

                pub fn deinit(_: *@This()) void {}
            };
            const Holder = struct {
                var impl = Impl{};
            };
            return drivers.wifi.Sta.make(&Holder.impl);
        }

        fn makeTestWifiAp() drivers.wifi.Ap {
            const Impl = struct {
                pub fn start(_: *@This(), _: drivers.wifi.Ap.Config) drivers.wifi.Ap.StartError!void {}

                pub fn stop(_: *@This()) void {}

                pub fn disconnectClient(_: *@This(), _: drivers.wifi.Ap.MacAddr) void {}

                pub fn getState(_: *@This()) drivers.wifi.Ap.State {
                    return .idle;
                }

                pub fn addEventHook(_: *@This(), _: ?*anyopaque, _: *const fn (?*anyopaque, drivers.wifi.Ap.Event) void) void {}

                pub fn removeEventHook(_: *@This(), _: ?*anyopaque, _: *const fn (?*anyopaque, drivers.wifi.Ap.Event) void) void {}

                pub fn getMacAddr(_: *@This()) ?drivers.wifi.Ap.MacAddr {
                    return null;
                }

                pub fn deinit(_: *@This()) void {}
            };
            const Holder = struct {
                var impl = Impl{};
            };
            return drivers.wifi.Ap.make(&Holder.impl);
        }

    };
}

fn comptimeEql(comptime a: []const u8, comptime b: []const u8) bool {
    if (a.len != b.len) return false;
    inline for (a, 0..) |ch, i| {
        if (ch != b[i]) return false;
    }
    return true;
}

fn comptimeStartsWith(comptime text: []const u8, comptime prefix: []const u8) bool {
    if (prefix.len > text.len) return false;
    inline for (prefix, 0..) |ch, i| {
        if (text[i] != ch) return false;
    }
    return true;
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const DummyChannel = struct {
        fn factory(comptime T: type) type {
            _ = T;
            return struct {};
        }
    }.factory;

    const TestCase = struct {
        const PairingFlow = blk: {
            const ui_flow = @import("component/ui/flow.zig");

            var builder = ui_flow.Builder.init();
            builder.addNode(.idle);
            builder.addNode(.done);
            builder.setInitial(.idle);
            builder.addEdge(.idle, .done, .confirm);
            break :blk builder.build();
        };

        fn parse_slice_dispatches_fragment_kinds(testing: anytype, _: lib.mem.Allocator) !void {
            const parsed = comptime parseSlice(
                \\{
                \\  "kind": "Reducer",
                \\  "spec": {
                \\    "label": "counter_reducer",
                \\    "reducer_fn_name": "counterReducer"
                \\  }
                \\}
            );

            switch (parsed) {
                .reducer => |reducer| {
                    try testing.expectEqualStrings("counter_reducer", reducer.label);
                    try testing.expectEqualStrings("counterReducer", reducer.reducer_fn_name);
                },
                else => return error.ExpectedReducerFragment,
            }
        }

        fn generated_type_exposes_declared_metadata(testing: anytype, _: lib.mem.Allocator) !void {
            const spec_doc = comptime blk: {
                break :blk switch (parseSlice(
                    \\{
                    \\  "kind": "Doc",
                    \\  "spec": [
                    \\    {
                    \\      "kind": "Store",
                    \\      "spec": {
                    \\        "label": "counter",
                    \\        "state": {
                    \\          "value": "u32"
                    \\        }
                    \\      }
                    \\    },
                    \\    {
                    \\      "kind": "StatePath",
                    \\      "spec": {
                    \\        "path": "ui",
                    \\        "labels": ["counter"]
                    \\      }
                    \\    },
                    \\    {
                    \\      "kind": "Component/button/single",
                    \\      "spec": {
                    \\        "label": "buttons",
                    \\        "id": 7
                    \\      }
                    \\    },
                    \\    {
                    \\      "kind": "Reducer",
                    \\      "spec": {
                    \\        "label": "counter_reducer",
                    \\        "reducer_fn_name": "counterReducer"
                    \\      }
                    \\    },
                    \\    {
                    \\      "kind": "Render",
                    \\      "spec": {
                    \\        "label": "counter_render",
                    \\        "state_path": "ui",
                    \\        "render_fn_name": "counterRender"
                    \\      }
                    \\    },
                    \\    {
                    \\      "kind": "UserStory",
                    \\      "spec": {
                    \\        "name": "warm up",
                    \\        "description": "walks a tick",
                    \\        "steps": [
                    \\          {
                    \\            "tick": {
                    \\              "interval": 42,
                    \\              "n": 1
                    \\            }
                    \\          }
                    \\        ]
                    \\      }
                    \\    }
                    \\  ]
                    \\}
                )) {
                    .doc => |value| value,
                    else => unreachable,
                };
            };
            const SpecType = comptime make(spec_doc);

            try testing.expectEqual(@as(usize, 1), SpecType.stores.len);
            try testing.expectEqualStrings("counter", SpecType.stores[0].Label);
            try testing.expect(@hasField(SpecType.stores[0].StateType, "value"));
            try testing.expect(@FieldType(SpecType.stores[0].StateType, "value") == u32);

            try testing.expectEqual(@as(usize, 1), SpecType.state_paths.len);
            try testing.expectEqualStrings("ui", SpecType.state_paths[0].path);
            try testing.expectEqual(@as(usize, 1), SpecType.state_paths[0].labels.len);
            try testing.expectEqualStrings("counter", SpecType.state_paths[0].labels[0]);

            try testing.expectEqual(@as(usize, 1), SpecType.components.len);
            try testing.expectEqualStrings("buttons", SpecType.components[0].label);
            try testing.expectEqual(@as(u32, 7), SpecType.components[0].id);
            switch (SpecType.components[0].kind) {
                .single_button => {},
                else => return error.ExpectedSingleButtonComponent,
            }

            try testing.expectEqual(@as(usize, 1), SpecType.reducers.len);
            try testing.expectEqualStrings("counter_reducer", SpecType.reducers[0].label);
            try testing.expectEqualStrings("counterReducer", SpecType.reducers[0].reducer_fn_name);

            try testing.expectEqual(@as(usize, 1), SpecType.renders.len);
            try testing.expectEqualStrings("counter_render", SpecType.renders[0].label);
            try testing.expectEqualStrings("ui", SpecType.renders[0].state_path);
            try testing.expectEqualStrings("counterRender", SpecType.renders[0].render_fn_name);

            try testing.expectEqual(@as(usize, 1), SpecType.user_stories.len);
            try testing.expectEqualStrings("warm up", SpecType.user_stories[0].name);
            try testing.expectEqualStrings("walks a tick", SpecType.user_stories[0].description);
            try testing.expectEqual(@as(usize, 1), SpecType.user_stories[0].steps.len);
            if (SpecType.user_stories[0].steps[0].tick) |tick| {
                try testing.expectEqual(@as(i128, 42), tick.interval);
                try testing.expectEqual(@as(usize, 1), tick.n);
            } else {
                return error.ExpectedTickStep;
            }
        }

        fn assembler_wires_declared_metadata(testing: anytype, _: lib.mem.Allocator) !void {
            const SpecType = make(.{
                .stores = &.{
                    StoreObjectSpecType.make("counter", struct {
                        value: u32,
                    }),
                },
                .state_paths = &.{
                    StatePathSpec{
                        .path = "ui",
                        .labels = &.{"counter"},
                    },
                },
                .reducers = &.{
                    ReducerSpec{
                        .label = "counter_reducer",
                        .reducer_fn_name = "counterReducer",
                    },
                },
                .renders = &.{
                    RenderSpec{
                        .label = "counter_render",
                        .state_path = "ui",
                        .render_fn_name = "counterRender",
                    },
                },
            });
            const ReducerFactory = struct {
                fn factory(
                    comptime StoresType: type,
                    comptime MessageType: type,
                    comptime EmitterType: type,
                ) Store.Reducer.ReducerFnType(StoresType, MessageType, EmitterType) {
                    return struct {
                        fn reduce(_: *StoresType, _: MessageType, _: EmitterType) !usize {
                            return 0;
                        }
                    }.reduce;
                }
            }.factory;
            const RenderFactory = struct {
                fn factory(comptime App: type, comptime path: []const u8) *const fn (*App) anyerror!void {
                    _ = path;

                    return struct {
                        fn render(_: *App) !void {}
                    }.render;
                }
            }.factory;

            const assembled = comptime blk: {
                var spec = SpecType.init();
                spec.setReducer("counter_reducer", ReducerFactory);
                spec.setRender("counter_render", RenderFactory);
                break :blk spec.assembler(lib, .{
                    .max_reducers = 1,
                    .max_handles = 1,
                    .store = .{
                        .max_stores = 1,
                        .max_state_nodes = 4,
                        .max_store_refs = 4,
                        .max_depth = 4,
                    },
                }, DummyChannel);
            };

            try testing.expectEqual(@as(usize, 1), assembled.store_builder.store_count);
            try testing.expectEqual(@as(usize, 1), assembled.store_builder.state_binding_count);
            try testing.expectEqual(@as(usize, 1), assembled.reducer_count);
            try testing.expectEqual(@as(usize, 1), assembled.render_count);
        }

        fn assembler_wires_flow_components(testing: anytype, _: lib.mem.Allocator) !void {
            const SpecType = make(.{
                .components = &.{
                    ComponentSpec{
                        .label = "pairing",
                        .id = 31,
                        .kind = .{
                            .flow = .{
                                .type_name = "PairingFlow",
                            },
                        },
                    },
                },
            });

            const assembled = comptime blk: {
                var spec = SpecType.init();
                spec.setFlow("pairing", PairingFlow);
                break :blk spec.assembler(lib, .{
                    .max_flows = 1,
                    .store = .{
                        .max_stores = 1,
                        .max_state_nodes = 4,
                        .max_store_refs = 4,
                        .max_depth = 4,
                    },
                }, DummyChannel);
            };

            try testing.expectEqual(@as(usize, 1), assembled.flow_registry.len);
            try testing.expectEqual(@as(u32, 31), assembled.flow_registry.periphs[0].id);
            try testing.expect(@hasDecl(assembled.flow_registry.periphs[0].FlowType, "Reducer"));
        }

        fn test_runner_executes_user_stories(testing: anytype, t: *testing_api.T, allocator: lib.mem.Allocator) !void {
            _ = allocator;
            const TestChannelImpl = struct {
                fn factory(comptime T: type) type {
                    return struct {
                        pub fn init(_: stdz.mem.Allocator, _: usize) !@This() {
                            return .{};
                        }

                        pub fn deinit(_: *@This()) void {}

                        pub fn close(_: *@This()) void {}

                        pub fn send(_: *@This(), _: T) !sync.channel.SendResult() {
                            return .{ .ok = false };
                        }

                        pub fn sendTimeout(_: *@This(), _: T, _: u32) !sync.channel.SendResult() {
                            return .{ .ok = false };
                        }

                        pub fn recv(_: *@This()) !sync.channel.RecvResult(T) {
                            return .{
                                .value = undefined,
                                .ok = false,
                            };
                        }

                        pub fn recvTimeout(_: *@This(), _: u32) !sync.channel.RecvResult(T) {
                            return .{
                                .value = undefined,
                                .ok = false,
                            };
                        }
                    };
                }
            }.factory;
            const TestChannel = sync.channel.make(TestChannelImpl);

            const SpecType = make(.{
                .stores = &.{
                    StoreObjectSpecType.make("counter", struct {
                        ticks: u32 = 0,
                    }),
                },
                .reducers = &.{
                    ReducerSpec{
                        .label = "counter_reducer",
                        .reducer_fn_name = "counterReducer",
                    },
                },
                .user_stories = &.{
                    UserStorySpec{
                        .name = "tick story",
                        .description = "updates store through the spec test runner",
                        .steps = &.{
                            .{
                                .outputs = &.{
                                    .{
                                        .label = "counter",
                                        .state = "{\"ticks\":0}",
                                    },
                                },
                            },
                            .{
                                .tick = .{
                                    .interval = 1,
                                    .n = 1,
                                },
                            },
                            .{
                                .outputs = &.{
                                    .{
                                        .label = "counter",
                                        .state = "{\"ticks\":1}",
                                    },
                                },
                            },
                        },
                    },
                },
            });
            const ReducerFactory = struct {
                fn factory(
                    comptime StoresType: type,
                    comptime MessageType: type,
                    comptime EmitterType: type,
                ) Store.Reducer.ReducerFnType(StoresType, MessageType, EmitterType) {
                    return struct {
                        fn reduce(stores: *StoresType, message: MessageType, emit: EmitterType) !usize {
                            _ = emit;
                            switch (message.body) {
                                .tick => {
                                    stores.counter.invoke({}, struct {
                                        fn apply(state: *@FieldType(StoresType, "counter").StateType, _: void) void {
                                            state.ticks += 1;
                                        }
                                    }.apply);
                                    return 1;
                                },
                                else => return 0,
                            }
                        }
                    }.reduce;
                }
            }.factory;

            const runner = comptime blk: {
                var spec = SpecType.init();
                spec.setReducer("counter_reducer", ReducerFactory);
                break :blk spec.testRunner(lib, .{
                    .max_reducers = 1,
                    .store = .{
                        .max_stores = 1,
                        .max_state_nodes = 4,
                        .max_store_refs = 4,
                        .max_depth = 4,
                    },
                }, TestChannel);
            };

            t.run("spec test runner", runner);
            try testing.expect(t.wait());
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            const testing = lib.testing;

            TestCase.parse_slice_dispatches_fragment_kinds(testing, allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.generated_type_exposes_declared_metadata(testing, allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.assembler_wires_declared_metadata(testing, allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.assembler_wires_flow_components(testing, allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.test_runner_executes_user_stories(testing, t, allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}

const Config = @import("assembler/Config.zig");
const assembler_builder = @import("assembler/Builder.zig");
const BuildContext = @import("assembler/BuildContext.zig");
const assembler_build_config = @import("assembler/BuildConfig.zig");
const registry_bt = @import("assembler/registry/bt.zig");
const registry_audio_system = @import("assembler/registry/audio_system.zig");
const registry_adc_button = @import("assembler/registry/adc_button.zig");
const registry_custom_event = @import("assembler/registry/custom_event.zig");
const registry_display = @import("assembler/registry/display.zig");
const registry_gpio = @import("assembler/registry/gpio.zig");
const registry_single_button = @import("assembler/registry/single_button.zig");
const registry_imu = @import("assembler/registry/imu.zig");
const registry_ledstrip = @import("assembler/registry/ledstrip.zig");
const registry_modem = @import("assembler/registry/modem.zig");
const registry_nfc = @import("assembler/registry/nfc.zig");
const registry_switch = @import("assembler/registry/switch.zig");
const registry_touch = @import("assembler/registry/touch.zig");
const registry_wifi_ap = @import("assembler/registry/wifi_ap.zig");
const registry_wifi_sta = @import("assembler/registry/wifi_sta.zig");
const registry_unique = @import("assembler/registry/unique.zig");
const Metadata = @import("Metadata.zig");
const Store = @import("Store.zig");

pub fn make(
    comptime grt: type,
    comptime config: Config,
) type {
    const StoreBuilderType = Store.Builder(config.store);
    const max_render_bindings = config.max_handles;
    const RenderBinding = struct {
        label: []const u8,
        name: []const u8,
        path: []const u8,
    };
    const ReducerBinding = struct {
        label: []const u8,
        name: []const u8,
    };
    const BtRegistryType = registry_bt.make(config.max_bt_hosts);
    const AdcButtonRegistryType = registry_adc_button.make(config.max_adc_buttons);
    const AudioSystemRegistryType = registry_audio_system.make(config.max_audio_systems);
    const DisplayRegistryType = registry_display.make(config.max_displays);
    const GpioRegistryType = registry_gpio.make(config.max_gpio);
    const SingleButtonRegistryType = registry_single_button.make(config.max_single_buttons);
    const ImuRegistryType = registry_imu.make(config.max_imu);
    const LedStripRegistryType = registry_ledstrip.make(config.max_led_strips);
    const ModemRegistryType = registry_modem.make(config.max_modem);
    const NfcRegistryType = registry_nfc.make(config.max_nfc);
    const SwitchRegistryType = registry_switch.makeSwitch(config.max_switches);
    const PwmRegistryType = registry_switch.makePwm(config.max_pwms);
    const TouchRegistryType = registry_touch.make(config.max_touch);
    const WifiStaRegistryType = registry_wifi_sta.make(config.max_wifi_sta);
    const WifiApRegistryType = registry_wifi_ap.make(config.max_wifi_ap);
    const CustomEventRegistryType = registry_custom_event.make(config.max_custom_events);

    return struct {
        const Self = @This();

        store_builder: StoreBuilderType,
        bt_registry: BtRegistryType,
        adc_button_registry: AdcButtonRegistryType,
        audio_system_registry: AudioSystemRegistryType,
        display_registry: DisplayRegistryType,
        gpio_registry: GpioRegistryType,
        single_button_registry: SingleButtonRegistryType,
        imu_registry: ImuRegistryType,
        ledstrip_registry: LedStripRegistryType,
        modem_registry: ModemRegistryType,
        nfc_registry: NfcRegistryType,
        switch_registry: SwitchRegistryType,
        pwm_registry: PwmRegistryType,
        touch_registry: TouchRegistryType,
        wifi_sta_registry: WifiStaRegistryType,
        wifi_ap_registry: WifiApRegistryType,
        custom_event_registry: CustomEventRegistryType,
        render_bindings: [max_render_bindings]RenderBinding = undefined,
        render_count: usize = 0,
        reducer_bindings: [config.max_reducers]ReducerBinding = undefined,
        reducer_count: usize = 0,

        pub const Lib = grt;
        pub const Config = config;
        pub const ChannelType = grt.sync.Channel;

        pub fn init() Self {
            return .{
                .store_builder = StoreBuilderType.init(),
                .bt_registry = BtRegistryType.init(),
                .adc_button_registry = AdcButtonRegistryType.init(),
                .audio_system_registry = AudioSystemRegistryType.init(),
                .display_registry = DisplayRegistryType.init(),
                .gpio_registry = GpioRegistryType.init(),
                .single_button_registry = SingleButtonRegistryType.init(),
                .imu_registry = ImuRegistryType.init(),
                .ledstrip_registry = LedStripRegistryType.init(),
                .modem_registry = ModemRegistryType.init(),
                .nfc_registry = NfcRegistryType.init(),
                .switch_registry = SwitchRegistryType.init(),
                .pwm_registry = PwmRegistryType.init(),
                .touch_registry = TouchRegistryType.init(),
                .wifi_sta_registry = WifiStaRegistryType.init(),
                .wifi_ap_registry = WifiApRegistryType.init(),
                .custom_event_registry = CustomEventRegistryType.init(),
            };
        }

        pub fn setStore(self: *Self, comptime label: []const u8, comptime StoreType: type) void {
            self.store_builder.setStore(label, StoreType);
        }

        pub fn setState(self: *Self, comptime path: []const u8, comptime labels: anytype) void {
            self.store_builder.setState(path, labels);
        }

        pub fn addRender(
            self: *Self,
            comptime label: []const u8,
            comptime path: []const u8,
        ) void {
            const label_name = validateRenderLabel(label);
            const normalized_path = validateRenderPath(path);
            if (self.render_count >= self.render_bindings.len) {
                @compileError("zux.Assembler.addRender exceeded max_handles");
            }

            self.render_bindings[self.render_count] = .{
                .label = label_name,
                .name = label_name,
                .path = normalized_path,
            };
            self.render_count += 1;
        }

        pub fn addReducer(
            self: *Self,
            comptime label: []const u8,
        ) void {
            const label_name = validateReducerLabel(label);

            if (self.reducer_count >= self.reducer_bindings.len) {
                @compileError("zux.Assembler.addReducer exceeded max_reducers");
            }
            if (hasReducerLabel(self, label_name)) {
                @compileError("zux.Assembler.addReducer duplicate reducer label '" ++ label_name ++ "'");
            }

            self.reducer_bindings[self.reducer_count] = .{
                .label = label_name,
                .name = label_name,
            };
            self.reducer_count += 1;
        }

        pub fn addGroupedButton(
            self: *Self,
            comptime label: []const u8,
            comptime id: u32,
            comptime button_count: usize,
        ) void {
            ensureComponentUnique(self, label, id);
            self.adc_button_registry.add(label, id, button_count);
        }

        pub fn addGroupedButtonWithMetadata(
            self: *Self,
            comptime label: []const u8,
            comptime id: u32,
            comptime metadata: Metadata,
            comptime button_count: usize,
        ) void {
            ensureComponentUnique(self, label, id);
            self.adc_button_registry.addWithMetadata(label, id, metadata, button_count);
        }

        pub fn addVirtualGroupedButton(
            self: *Self,
            comptime label: []const u8,
            comptime id: u32,
            comptime button_count: usize,
        ) void {
            ensureComponentUnique(self, label, id);
            self.adc_button_registry.addVirtual(label, id, button_count);
        }

        pub fn addVirtualGroupedButtonWithMetadata(
            self: *Self,
            comptime label: []const u8,
            comptime id: u32,
            comptime metadata: Metadata,
            comptime button_count: usize,
        ) void {
            ensureComponentUnique(self, label, id);
            self.adc_button_registry.addVirtualWithMetadata(label, id, metadata, button_count);
        }

        pub fn addSingleButton(
            self: *Self,
            comptime label: []const u8,
            comptime id: u32,
        ) void {
            ensureComponentUnique(self, label, id);
            self.single_button_registry.add(label, id);
        }

        pub fn addSingleButtonWithMetadata(
            self: *Self,
            comptime label: []const u8,
            comptime id: u32,
            comptime metadata: Metadata,
        ) void {
            ensureComponentUnique(self, label, id);
            self.single_button_registry.addWithMetadata(label, id, metadata);
        }

        pub fn addVirtualSingleButton(
            self: *Self,
            comptime label: []const u8,
            comptime id: u32,
        ) void {
            ensureComponentUnique(self, label, id);
            self.single_button_registry.addVirtual(label, id);
        }

        pub fn addVirtualSingleButtonWithMetadata(
            self: *Self,
            comptime label: []const u8,
            comptime id: u32,
            comptime metadata: Metadata,
        ) void {
            ensureComponentUnique(self, label, id);
            self.single_button_registry.addVirtualWithMetadata(label, id, metadata);
        }

        pub fn addAudioSystem(
            self: *Self,
            comptime label: []const u8,
            comptime id: u32,
        ) void {
            ensureComponentUnique(self, label, id);
            self.audio_system_registry.add(label, id);
        }

        pub fn addAudioSystemWithMetadata(self: *Self, comptime label: []const u8, comptime id: u32, comptime metadata: Metadata) void {
            ensureComponentUnique(self, label, id);
            self.audio_system_registry.addWithMetadata(label, id, metadata);
        }

        pub fn addBt(
            self: *Self,
            comptime label: []const u8,
            comptime id: u32,
        ) void {
            ensureComponentUnique(self, label, id);
            self.bt_registry.add(label, id);
        }

        pub fn addBtWithMetadata(self: *Self, comptime label: []const u8, comptime id: u32, comptime metadata: Metadata) void {
            ensureComponentUnique(self, label, id);
            self.bt_registry.addWithMetadata(label, id, metadata);
        }

        pub fn addDisplay(
            self: *Self,
            comptime label: []const u8,
            comptime id: u32,
        ) void {
            ensureComponentUnique(self, label, id);
            self.display_registry.add(label, id);
        }

        pub fn addDisplayWithMetadata(self: *Self, comptime label: []const u8, comptime id: u32, comptime metadata: Metadata) void {
            ensureComponentUnique(self, label, id);
            self.display_registry.addWithMetadata(label, id, metadata);
        }

        pub fn addDisplayWithMetadataAndSize(
            self: *Self,
            comptime label: []const u8,
            comptime id: u32,
            comptime metadata: Metadata,
            comptime width: u16,
            comptime height: u16,
        ) void {
            ensureComponentUnique(self, label, id);
            self.display_registry.addWithMetadataAndSize(label, id, metadata, width, height);
        }

        pub fn addGpio(
            self: *Self,
            comptime label: []const u8,
            comptime id: u32,
        ) void {
            ensureComponentUnique(self, label, id);
            self.gpio_registry.add(label, id);
        }

        pub fn addGpioWithMetadata(
            self: *Self,
            comptime label: []const u8,
            comptime id: u32,
            comptime metadata: Metadata,
        ) void {
            ensureComponentUnique(self, label, id);
            self.gpio_registry.addWithMetadata(label, id, metadata);
        }

        pub fn addIrqGpio(
            self: *Self,
            comptime label: []const u8,
            comptime id: u32,
        ) void {
            ensureComponentUnique(self, label, id);
            self.gpio_registry.addIrq(label, id);
        }

        pub fn addIrqGpioWithMetadata(
            self: *Self,
            comptime label: []const u8,
            comptime id: u32,
            comptime metadata: Metadata,
        ) void {
            ensureComponentUnique(self, label, id);
            self.gpio_registry.addIrqWithMetadata(label, id, metadata);
        }

        pub fn addVirtualGpio(
            self: *Self,
            comptime label: []const u8,
            comptime id: u32,
        ) void {
            ensureComponentUnique(self, label, id);
            self.gpio_registry.addVirtual(label, id);
        }

        pub fn addVirtualGpioWithMetadata(
            self: *Self,
            comptime label: []const u8,
            comptime id: u32,
            comptime metadata: Metadata,
        ) void {
            ensureComponentUnique(self, label, id);
            self.gpio_registry.addVirtualWithMetadata(label, id, metadata);
        }

        pub fn addImu(
            self: *Self,
            comptime label: []const u8,
            comptime id: u32,
        ) void {
            ensureComponentUnique(self, label, id);
            self.imu_registry.add(label, id);
        }

        pub fn addImuWithMetadata(self: *Self, comptime label: []const u8, comptime id: u32, comptime metadata: Metadata) void {
            ensureComponentUnique(self, label, id);
            self.imu_registry.addWithMetadata(label, id, metadata);
        }

        pub fn addLedStrip(
            self: *Self,
            comptime label: []const u8,
            comptime id: u32,
            comptime pixel_count: usize,
        ) void {
            ensureComponentUnique(self, label, id);
            self.ledstrip_registry.add(label, id, pixel_count);
        }

        pub fn addLedStripWithMetadata(
            self: *Self,
            comptime label: []const u8,
            comptime id: u32,
            comptime metadata: Metadata,
            comptime pixel_count: usize,
        ) void {
            ensureComponentUnique(self, label, id);
            self.ledstrip_registry.addWithMetadata(label, id, metadata, pixel_count);
        }

        pub fn addModem(
            self: *Self,
            comptime label: []const u8,
            comptime id: u32,
        ) void {
            ensureComponentUnique(self, label, id);
            self.modem_registry.add(label, id);
        }

        pub fn addModemWithMetadata(self: *Self, comptime label: []const u8, comptime id: u32, comptime metadata: Metadata) void {
            ensureComponentUnique(self, label, id);
            self.modem_registry.addWithMetadata(label, id, metadata);
        }

        pub fn addNfc(
            self: *Self,
            comptime label: []const u8,
            comptime id: u32,
        ) void {
            ensureComponentUnique(self, label, id);
            self.nfc_registry.add(label, id);
        }

        pub fn addNfcWithMetadata(self: *Self, comptime label: []const u8, comptime id: u32, comptime metadata: Metadata) void {
            ensureComponentUnique(self, label, id);
            self.nfc_registry.addWithMetadata(label, id, metadata);
        }

        pub fn addSwitch(
            self: *Self,
            comptime label: []const u8,
            comptime id: u32,
        ) void {
            ensureComponentUnique(self, label, id);
            self.switch_registry.add(label, id);
        }

        pub fn addSwitchWithMetadata(self: *Self, comptime label: []const u8, comptime id: u32, comptime metadata: Metadata) void {
            ensureComponentUnique(self, label, id);
            self.switch_registry.addWithMetadata(label, id, metadata);
        }

        pub fn addPwm(
            self: *Self,
            comptime label: []const u8,
            comptime id: u32,
        ) void {
            ensureComponentUnique(self, label, id);
            self.pwm_registry.add(label, id);
        }

        pub fn addPwmWithMetadata(self: *Self, comptime label: []const u8, comptime id: u32, comptime metadata: Metadata) void {
            ensureComponentUnique(self, label, id);
            self.pwm_registry.addWithMetadata(label, id, metadata);
        }

        pub fn addTouch(
            self: *Self,
            comptime label: []const u8,
            comptime id: u32,
            comptime target: ?[]const u8,
        ) void {
            ensureComponentUnique(self, label, id);
            self.touch_registry.add(label, id, target);
        }

        pub fn addTouchWithMetadata(
            self: *Self,
            comptime label: []const u8,
            comptime id: u32,
            comptime metadata: Metadata,
            comptime target: ?[]const u8,
        ) void {
            ensureComponentUnique(self, label, id);
            self.touch_registry.addWithMetadata(label, id, metadata, target);
        }

        pub fn addWifiSta(
            self: *Self,
            comptime label: []const u8,
            comptime id: u32,
        ) void {
            ensureComponentUnique(self, label, id);
            self.wifi_sta_registry.add(label, id);
        }

        pub fn addWifiStaWithMetadata(self: *Self, comptime label: []const u8, comptime id: u32, comptime metadata: Metadata) void {
            ensureComponentUnique(self, label, id);
            self.wifi_sta_registry.addWithMetadata(label, id, metadata);
        }

        pub fn addWifiAp(
            self: *Self,
            comptime label: []const u8,
            comptime id: u32,
        ) void {
            ensureComponentUnique(self, label, id);
            self.wifi_ap_registry.add(label, id);
        }

        pub fn addWifiApWithMetadata(self: *Self, comptime label: []const u8, comptime id: u32, comptime metadata: Metadata) void {
            ensureComponentUnique(self, label, id);
            self.wifi_ap_registry.addWithMetadata(label, id, metadata);
        }

        pub fn registerCustomEvent(self: *Self, comptime EventType: type) void {
            self.custom_event_registry.add(EventType);
        }

        pub fn BuildConfig(comptime self: Self) type {
            return assembler_build_config.make(.{
                .bt = self.bt_registry,
                .adc_button = self.adc_button_registry,
                .audio_system = self.audio_system_registry,
                .display = self.display_registry,
                .gpio = self.gpio_registry,
                .single_button = self.single_button_registry,
                .imu = self.imu_registry,
                .ledstrip = self.ledstrip_registry,
                .modem = self.modem_registry,
                .nfc = self.nfc_registry,
                .switch_output = self.switch_registry,
                .pwm = self.pwm_registry,
                .touch = self.touch_registry,
                .wifi_sta = self.wifi_sta_registry,
                .wifi_ap = self.wifi_ap_registry,
            });
        }

        pub fn build(
            comptime self: Self,
            comptime build_config: self.BuildConfig(),
        ) type {
            return assembler_builder.init().build(BuildContext.make(.{
                .grt = grt,
                .assembler_config = config,
                .build_config = build_config,
                .registries = .{
                    .bt = self.bt_registry,
                    .adc_button = self.adc_button_registry,
                    .audio_system = self.audio_system_registry,
                    .display = self.display_registry,
                    .gpio = self.gpio_registry,
                    .single_button = self.single_button_registry,
                    .imu = self.imu_registry,
                    .ledstrip = self.ledstrip_registry,
                    .modem = self.modem_registry,
                    .nfc = self.nfc_registry,
                    .switch_output = self.switch_registry,
                    .pwm = self.pwm_registry,
                    .touch = self.touch_registry,
                    .wifi_sta = self.wifi_sta_registry,
                    .wifi_ap = self.wifi_ap_registry,
                },
                .store_builder = self.store_builder,
                .render_bindings = self.render_bindings,
                .render_count = self.render_count,
                .reducer_bindings = self.reducer_bindings,
                .reducer_count = self.reducer_count,
                .custom_event_registar = self.custom_event_registry.Registar(),
            }));
        }

        fn ensureComponentUnique(
            self: *Self,
            comptime label: []const u8,
            comptime id: u32,
        ) void {
            const label_name = registry_unique.labelText(label);
            registry_unique.ensureUniqueAcross(
                .{
                    self.adc_button_registry,
                    self.bt_registry,
                    self.audio_system_registry,
                    self.display_registry,
                    self.gpio_registry,
                    self.single_button_registry,
                    self.imu_registry,
                    self.ledstrip_registry,
                    self.modem_registry,
                    self.nfc_registry,
                    self.switch_registry,
                    self.pwm_registry,
                    self.touch_registry,
                    self.wifi_sta_registry,
                    self.wifi_ap_registry,
                },
                label_name,
                id,
                "zux.Assembler duplicate component label",
                "zux.Assembler duplicate component id",
            );
        }

        fn validateReducerLabel(comptime label: []const u8) []const u8 {
            if (label.len == 0) {
                @compileError("zux.Assembler.addReducer labels must not be empty");
            }
            return label;
        }

        fn validateRenderLabel(comptime label: []const u8) []const u8 {
            if (label.len == 0) {
                @compileError("zux.Assembler.addRender labels must not be empty");
            }
            return label;
        }

        fn hasReducerLabel(self: *Self, comptime label: []const u8) bool {
            inline for (0..self.reducer_count) |i| {
                if (comptimeEql(self.reducer_bindings[i].label, label)) return true;
            }
            return false;
        }

        fn validateRenderPath(comptime path: []const u8) []const u8 {
            if (path.len == 0) {
                @compileError("zux.Assembler.addRender paths must not be empty");
            }
            if (storePathLabel(path)) |_| {
                return path;
            }
            if (path[0] == '/' or path[path.len - 1] == '/') {
                @compileError("zux.Assembler.addRender paths must not start or end with '/'");
            }

            comptime var segment_start: usize = 0;
            inline for (path, 0..) |ch, idx| {
                if (ch == '.') {
                    @compileError("zux.Assembler.addRender paths must use '/' separators instead of '.'");
                }
                if (ch == '/') {
                    if (idx == segment_start) {
                        @compileError("zux.Assembler.addRender paths must not contain empty segments");
                    }
                    segment_start = idx + 1;
                }
            }

            if (segment_start == path.len) {
                @compileError("zux.Assembler.addRender paths must not contain empty segments");
            }
            return path;
        }

        fn storePathLabel(comptime path: []const u8) ?[]const u8 {
            const prefix = "$store/";
            if (path.len <= prefix.len) return null;
            inline for (prefix, 0..) |ch, idx| {
                if (path[idx] != ch) return null;
            }
            const label = path[prefix.len..];
            inline for (label) |ch| {
                if (ch == '/') {
                    @compileError("zux.Assembler.addRender $store paths must be exactly $store/{store_label}");
                }
                if (ch == '.') {
                    @compileError("zux.Assembler.addRender $store labels must not contain dots");
                }
            }
            return label;
        }

        fn comptimeEql(comptime a: []const u8, comptime b: []const u8) bool {
            if (a.len != b.len) return false;
            inline for (a, 0..) |ch, idx| {
                if (ch != b[idx]) return false;
            }
            return true;
        }
    };
}

//! HAL Board aggregation and unified event queue.
//!
//! 参考旧版 board：
//! - 自动发现 HAL 外设类型（基于 `_hal_marker`）
//! - 自动初始化 driver 与 wrapper
//! - 提供统一事件队列（nextEvent/sendEvent）
//! - 在 `nextEvent()` 前自动轮询可轮询外设（button/wifi/ble）

const std = @import("std");
const hal_marker = @import("marker.zig");
const event_mod = @import("event.zig");
const rtc_mod = @import("rtc.zig");

// ============================================================================
// Queue
// ============================================================================

pub fn SimpleQueue(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        buffer: [capacity]T = undefined,
        head: usize = 0,
        tail: usize = 0,
        size: usize = 0,

        pub fn init() Self {
            return .{};
        }

        pub fn deinit(_: *Self) void {}

        pub fn trySend(self: *Self, item: T) bool {
            if (self.size >= capacity) return false;
            self.buffer[self.tail] = item;
            self.tail = (self.tail + 1) % capacity;
            self.size += 1;
            return true;
        }

        pub fn tryReceive(self: *Self) ?T {
            if (self.size == 0) return null;
            const item = self.buffer[self.head];
            self.head = (self.head + 1) % capacity;
            self.size -= 1;
            return item;
        }

        pub fn count(self: *const Self) usize {
            return self.size;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.size == 0;
        }

        pub fn reset(self: *Self) void {
            self.head = 0;
            self.tail = 0;
            self.size = 0;
        }
    };
}

// ============================================================================
// Comptime helpers
// ============================================================================

fn getMarkedKind(comptime T: type) ?hal_marker.Kind {
    if (@typeInfo(T) != .@"struct") return null;
    if (!@hasDecl(T, "_hal_marker")) return null;
    const marker = T._hal_marker;
    if (@TypeOf(marker) != hal_marker.Marker) return null;
    return marker.kind;
}

fn findPeripheralType(comptime spec: type, comptime kind: hal_marker.Kind) type {
    var found = false;
    var result: type = void;

    inline for (@typeInfo(spec).@"struct".decls) |decl| {
        if (!@hasDecl(spec, decl.name)) continue;

        const DeclType = @TypeOf(@field(spec, decl.name));
        if (@typeInfo(DeclType) != .type) continue;

        const Candidate = @field(spec, decl.name);
        if (getMarkedKind(Candidate)) |k| {
            if (k == kind) {
                if (found) {
                    @compileError(std.fmt.comptimePrint(
                        "spec contains multiple HAL peripherals for marker kind '{s}'",
                        .{@tagName(kind)},
                    ));
                }
                found = true;
                result = Candidate;
            }
        }
    }

    return result;
}

fn findRtcReaderType(comptime spec: type) type {
    var found = false;
    var result: type = void;

    inline for (@typeInfo(spec).@"struct".decls) |decl| {
        if (!@hasDecl(spec, decl.name)) continue;

        const DeclType = @TypeOf(@field(spec, decl.name));
        if (@typeInfo(DeclType) != .type) continue;

        const Candidate = @field(spec, decl.name);
        if (getMarkedKind(Candidate)) |kind| {
            if (kind != .rtc) continue;

            // 仅接受 reader 能力（uptime/nowMs）
            if (!@hasDecl(Candidate, "uptime") or !@hasDecl(Candidate, "nowMs")) continue;

            _ = @as(*const fn (*Candidate) u64, &Candidate.uptime);
            _ = @as(*const fn (*Candidate) ?i64, &Candidate.nowMs);

            if (found) {
                @compileError("spec has multiple rtc reader-like peripherals; keep only one");
            }
            found = true;
            result = Candidate;
        }
    }

    if (!found) {
        @compileError("spec must provide one rtc reader peripheral (marker kind .rtc, with uptime/nowMs)");
    }

    return result;
}

fn driverTypeOf(comptime PeripheralType: type) type {
    if (PeripheralType == void) return void;
    if (!@hasDecl(PeripheralType, "DriverType")) {
        @compileError("HAL peripheral type must expose DriverType");
    }
    return PeripheralType.DriverType;
}

fn validatePeripheralType(comptime PeripheralType: type, comptime expected_kind: hal_marker.Kind) void {
    if (PeripheralType == void) return;

    if (getMarkedKind(PeripheralType)) |k| {
        if (k != expected_kind) {
            @compileError(std.fmt.comptimePrint(
                "HAL peripheral marker kind mismatch: expected '{s}', got '{s}'",
                .{ @tagName(expected_kind), @tagName(k) },
            ));
        }
    } else {
        @compileError("HAL peripheral is missing valid shared marker (_hal_marker: hal.marker.Marker)");
    }

    const DriverType = driverTypeOf(PeripheralType);

    if (!@hasDecl(PeripheralType, "init")) {
        @compileError("HAL peripheral must expose init(*DriverType)");
    }
    _ = @as(*const fn (*DriverType) PeripheralType, &PeripheralType.init);

    if (!@hasDecl(DriverType, "init")) {
        @compileError("driver type must expose init() for board auto-init");
    }

    // 允许 `init() Driver` 或 `init() !Driver`
    const init_ret = @typeInfo(@TypeOf(DriverType.init)).@"fn".return_type orelse
        @compileError("driver init must have a return type");

    switch (@typeInfo(init_ret)) {
        .error_union => |eu| {
            if (eu.payload != DriverType) {
                @compileError("driver init() error-union payload must be DriverType");
            }
        },
        else => {
            if (init_ret != DriverType) {
                @compileError("driver init() must return DriverType or !DriverType");
            }
        },
    }

    if (comptime @hasDecl(DriverType, "deinit")) {
        _ = @as(*const fn (*DriverType) void, &DriverType.deinit);
    }
}

fn optionalChildOrVoid(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => void,
    };
}

const PollStyle = enum {
    none,
    poll_event_noarg,
    poll_event_noarg_err,
    poll_i32,
    poll_i32_err,
    poll_u64,
    poll_u64_err,
};

fn eventPayloadFromReturnType(comptime Ret: type) type {
    return switch (@typeInfo(Ret)) {
        .optional => |o| o.child,
        .error_union => |eu| switch (@typeInfo(eu.payload)) {
            .optional => |o| o.child,
            else => void,
        },
        else => void,
    };
}

fn getPollStyle(comptime PeripheralType: type) PollStyle {
    if (PeripheralType == void) return .none;

    if (@hasDecl(PeripheralType, "pollEvent")) {
        const fn_info = @typeInfo(@TypeOf(PeripheralType.pollEvent)).@"fn";
        if (fn_info.params.len == 1) {
            if (fn_info.return_type) |ret| {
                return switch (@typeInfo(ret)) {
                    .optional => if (optionalChildOrVoid(ret) != void) .poll_event_noarg else .none,
                    .error_union => |eu| switch (@typeInfo(eu.payload)) {
                        .optional => |o| if (o.child != void) .poll_event_noarg_err else .none,
                        else => .none,
                    },
                    else => .none,
                };
            }
        }
    }

    if (@hasDecl(PeripheralType, "poll")) {
        const fn_info = @typeInfo(@TypeOf(PeripheralType.poll)).@"fn";
        if (fn_info.params.len == 2) {
            const p1 = fn_info.params[1].type orelse return .none;
            const ret = fn_info.return_type orelse return .none;

            const is_opt = switch (@typeInfo(ret)) {
                .optional => true,
                .error_union => |eu| switch (@typeInfo(eu.payload)) {
                    .optional => true,
                    else => false,
                },
                else => false,
            };
            if (!is_opt) return .none;
            if (eventPayloadFromReturnType(ret) == void) return .none;

            const is_err = @typeInfo(ret) == .error_union;
            if (p1 == i32) return if (is_err) .poll_i32_err else .poll_i32;
            if (p1 == u64) return if (is_err) .poll_u64_err else .poll_u64;
        }
    }

    return .none;
}

fn pollPayloadType(comptime PeripheralType: type) type {
    if (PeripheralType == void) return void;

    if (@hasDecl(PeripheralType, "pollEvent")) {
        const fn_info = @typeInfo(@TypeOf(PeripheralType.pollEvent)).@"fn";
        if (fn_info.params.len == 1) {
            if (fn_info.return_type) |ret| {
                return eventPayloadFromReturnType(ret);
            }
        }
    }

    if (@hasDecl(PeripheralType, "poll")) {
        const fn_info = @typeInfo(@TypeOf(PeripheralType.poll)).@"fn";
        if (fn_info.params.len == 2) {
            if (fn_info.return_type) |ret| {
                return eventPayloadFromReturnType(ret);
            }
        }
    }

    return void;
}

fn typeOrEmpty(comptime T: type) type {
    return if (T == void) event_mod.Empty else T;
}

fn driverInit(comptime DriverType: type) !DriverType {
    return DriverType.init();
}

fn driverDeinit(comptime DriverType: type, driver: *DriverType) void {
    if (comptime @hasDecl(DriverType, "deinit")) {
        driver.deinit();
    }
}

// ============================================================================
// Board
// ============================================================================

pub fn Board(comptime spec: type) type {
    comptime {
        if (!@hasDecl(spec, "meta")) {
            @compileError("spec must define meta.id");
        }
        _ = @as([]const u8, spec.meta.id);

        if (@hasDecl(spec, "queue_capacity")) {
            const cap = @as(usize, spec.queue_capacity);
            if (cap == 0) @compileError("spec.queue_capacity must be > 0");
        }
    }

    const RtcType = findRtcReaderType(spec);
    const ButtonType = findPeripheralType(spec, .button);
    const LedType = findPeripheralType(spec, .led);
    const LedStripType = findPeripheralType(spec, .led_strip);
    const DisplayType = findPeripheralType(spec, .display);
    const MicType = findPeripheralType(spec, .mic);
    const SpeakerType = findPeripheralType(spec, .speaker);
    const TempSensorType = findPeripheralType(spec, .temp_sensor);
    const ImuType = findPeripheralType(spec, .imu);
    const GpioType = findPeripheralType(spec, .gpio);
    const AdcType = findPeripheralType(spec, .adc);
    const PwmType = findPeripheralType(spec, .pwm);
    const I2cType = findPeripheralType(spec, .i2c);
    const SpiType = findPeripheralType(spec, .spi);
    const UartType = findPeripheralType(spec, .uart);
    const WifiType = findPeripheralType(spec, .wifi);
    const BleType = findPeripheralType(spec, .ble);
    const HciType = findPeripheralType(spec, .hci);
    const KvsType = findPeripheralType(spec, .kvs);
    const MotionType = findPeripheralType(spec, .motion);

    comptime {
        validatePeripheralType(RtcType, .rtc);
        validatePeripheralType(ButtonType, .button);
        validatePeripheralType(LedType, .led);
        validatePeripheralType(LedStripType, .led_strip);
        validatePeripheralType(DisplayType, .display);
        validatePeripheralType(MicType, .mic);
        validatePeripheralType(SpeakerType, .speaker);
        validatePeripheralType(TempSensorType, .temp_sensor);
        validatePeripheralType(ImuType, .imu);
        validatePeripheralType(GpioType, .gpio);
        validatePeripheralType(AdcType, .adc);
        validatePeripheralType(PwmType, .pwm);
        validatePeripheralType(I2cType, .i2c);
        validatePeripheralType(SpiType, .spi);
        validatePeripheralType(UartType, .uart);
        validatePeripheralType(WifiType, .wifi);
        validatePeripheralType(BleType, .ble);
        validatePeripheralType(HciType, .hci);
        validatePeripheralType(KvsType, .kvs);
        validatePeripheralType(MotionType, .motion);
    }

    const RtcDriverType = driverTypeOf(RtcType);
    const ButtonDriverType = driverTypeOf(ButtonType);
    const LedDriverType = driverTypeOf(LedType);
    const LedStripDriverType = driverTypeOf(LedStripType);
    const DisplayDriverType = driverTypeOf(DisplayType);
    const MicDriverType = driverTypeOf(MicType);
    const SpeakerDriverType = driverTypeOf(SpeakerType);
    const TempSensorDriverType = driverTypeOf(TempSensorType);
    const ImuDriverType = driverTypeOf(ImuType);
    const GpioDriverType = driverTypeOf(GpioType);
    const AdcDriverType = driverTypeOf(AdcType);
    const PwmDriverType = driverTypeOf(PwmType);
    const I2cDriverType = driverTypeOf(I2cType);
    const SpiDriverType = driverTypeOf(SpiType);
    const UartDriverType = driverTypeOf(UartType);
    const WifiDriverType = driverTypeOf(WifiType);
    const BleDriverType = driverTypeOf(BleType);
    const HciDriverType = driverTypeOf(HciType);
    const KvsDriverType = driverTypeOf(KvsType);
    const MotionDriverType = driverTypeOf(MotionType);

    const HasButton = ButtonType != void;
    const HasLed = LedType != void;
    const HasLedStrip = LedStripType != void;
    const HasDisplay = DisplayType != void;
    const HasMic = MicType != void;
    const HasSpeaker = SpeakerType != void;
    const HasTempSensor = TempSensorType != void;
    const HasImu = ImuType != void;
    const HasGpio = GpioType != void;
    const HasAdc = AdcType != void;
    const HasPwm = PwmType != void;
    const HasI2c = I2cType != void;
    const HasSpi = SpiType != void;
    const HasUart = UartType != void;
    const HasWifi = WifiType != void;
    const HasBle = BleType != void;
    const HasHci = HciType != void;
    const HasKvs = KvsType != void;
    const HasMotion = MotionType != void;

    const has_led_strip_clear = comptime HasLedStrip and @hasDecl(LedStripType, "clear");
    const has_led_off = comptime HasLed and @hasDecl(LedType, "off");
    const has_rtc_now = comptime @hasDecl(RtcType, "now");

    const ButtonEventPayload = pollPayloadType(ButtonType);
    const WifiEventPayload = pollPayloadType(WifiType);
    const BleEventPayload = pollPayloadType(BleType);
    const MotionEventPayload = pollPayloadType(MotionType);

    const DefaultEvent = event_mod.UnifiedEvent(
        typeOrEmpty(ButtonEventPayload),
        typeOrEmpty(WifiEventPayload),
        typeOrEmpty(BleEventPayload),
        event_mod.Empty,
        typeOrEmpty(MotionEventPayload),
    );

    const EventType = if (@hasDecl(spec, "EventType")) spec.EventType else DefaultEvent;
    const UsesDefaultEvent = !@hasDecl(spec, "EventType");

    const QueueCapacity = if (@hasDecl(spec, "queue_capacity")) @as(usize, spec.queue_capacity) else 64;
    const QueueFactory = if (@hasDecl(spec, "Queue")) spec.Queue else SimpleQueue;
    const EventQueueType = QueueFactory(EventType, QueueCapacity);

    return struct {
        const Self = @This();

        pub const meta = spec.meta;
        pub const Event = EventType;
        pub const Queue = EventQueueType;

        pub const log = if (@hasDecl(spec, "log")) spec.log else void;
        pub const time = if (@hasDecl(spec, "time")) spec.time else void;
        pub const isRunning = if (@hasDecl(spec, "isRunning"))
            spec.isRunning
        else
            struct {
                fn always() bool {
                    return true;
                }
            }.always;

        pub const rtc = RtcType;
        pub const button = ButtonType;
        pub const led = LedType;
        pub const led_strip = LedStripType;
        pub const display = DisplayType;
        pub const mic = MicType;
        pub const speaker = SpeakerType;
        pub const temp_sensor = TempSensorType;
        pub const imu = ImuType;
        pub const gpio = GpioType;
        pub const adc = AdcType;
        pub const pwm = PwmType;
        pub const i2c = I2cType;
        pub const spi = SpiType;
        pub const uart = UartType;
        pub const wifi = WifiType;
        pub const ble = BleType;
        pub const hci = HciType;
        pub const kvs = KvsType;
        pub const motion = MotionType;

        events: EventQueueType,
        queue_inited: bool = false,

        rtc_driver: RtcDriverType,
        rtc_dev: RtcType,
        init_rtc: bool = false,

        button_driver: if (HasButton) ButtonDriverType else void,
        button_dev: if (HasButton) ButtonType else void,
        init_button: bool = false,

        led_driver: if (HasLed) LedDriverType else void,
        led_dev: if (HasLed) LedType else void,
        init_led: bool = false,

        led_strip_driver: if (HasLedStrip) LedStripDriverType else void,
        led_strip_dev: if (HasLedStrip) LedStripType else void,
        init_led_strip: bool = false,

        display_driver: if (HasDisplay) DisplayDriverType else void,
        display_dev: if (HasDisplay) DisplayType else void,
        init_display: bool = false,

        mic_driver: if (HasMic) MicDriverType else void,
        mic_dev: if (HasMic) MicType else void,
        init_mic: bool = false,

        speaker_driver: if (HasSpeaker) SpeakerDriverType else void,
        speaker_dev: if (HasSpeaker) SpeakerType else void,
        init_speaker: bool = false,

        temp_sensor_driver: if (HasTempSensor) TempSensorDriverType else void,
        temp_sensor_dev: if (HasTempSensor) TempSensorType else void,
        init_temp_sensor: bool = false,

        imu_driver: if (HasImu) ImuDriverType else void,
        imu_dev: if (HasImu) ImuType else void,
        init_imu: bool = false,

        gpio_driver: if (HasGpio) GpioDriverType else void,
        gpio_dev: if (HasGpio) GpioType else void,
        init_gpio: bool = false,

        adc_driver: if (HasAdc) AdcDriverType else void,
        adc_dev: if (HasAdc) AdcType else void,
        init_adc: bool = false,

        pwm_driver: if (HasPwm) PwmDriverType else void,
        pwm_dev: if (HasPwm) PwmType else void,
        init_pwm: bool = false,

        i2c_driver: if (HasI2c) I2cDriverType else void,
        i2c_dev: if (HasI2c) I2cType else void,
        init_i2c: bool = false,

        spi_driver: if (HasSpi) SpiDriverType else void,
        spi_dev: if (HasSpi) SpiType else void,
        init_spi: bool = false,

        uart_driver: if (HasUart) UartDriverType else void,
        uart_dev: if (HasUart) UartType else void,
        init_uart: bool = false,

        wifi_driver: if (HasWifi) WifiDriverType else void,
        wifi_dev: if (HasWifi) WifiType else void,
        init_wifi: bool = false,

        ble_driver: if (HasBle) BleDriverType else void,
        ble_dev: if (HasBle) BleType else void,
        init_ble: bool = false,

        hci_driver: if (HasHci) HciDriverType else void,
        hci_dev: if (HasHci) HciType else void,
        init_hci: bool = false,

        kvs_driver: if (HasKvs) KvsDriverType else void,
        kvs_dev: if (HasKvs) KvsType else void,
        init_kvs: bool = false,

        motion_driver: if (HasMotion) MotionDriverType else void,
        motion_dev: if (HasMotion) MotionType else void,
        init_motion: bool = false,

        pub fn init(self: *Self) !void {
            self.events = EventQueueType.init();
            self.queue_inited = true;

            self.init_rtc = false;
            self.init_button = false;
            self.init_led = false;
            self.init_led_strip = false;
            self.init_display = false;
            self.init_mic = false;
            self.init_speaker = false;
            self.init_temp_sensor = false;
            self.init_imu = false;
            self.init_gpio = false;
            self.init_adc = false;
            self.init_pwm = false;
            self.init_i2c = false;
            self.init_spi = false;
            self.init_uart = false;
            self.init_wifi = false;
            self.init_ble = false;
            self.init_hci = false;
            self.init_kvs = false;
            self.init_motion = false;

            errdefer self.deinit();

            self.rtc_driver = try driverInit(RtcDriverType);
            self.rtc_dev = RtcType.init(&self.rtc_driver);
            self.init_rtc = true;

            if (HasButton) {
                self.button_driver = try driverInit(ButtonDriverType);
                self.button_dev = ButtonType.init(&self.button_driver);
                self.init_button = true;
            }

            if (HasLed) {
                self.led_driver = try driverInit(LedDriverType);
                self.led_dev = LedType.init(&self.led_driver);
                self.init_led = true;
            }

            if (HasLedStrip) {
                self.led_strip_driver = try driverInit(LedStripDriverType);
                self.led_strip_dev = LedStripType.init(&self.led_strip_driver);
                self.init_led_strip = true;
            }

            if (HasDisplay) {
                self.display_driver = try driverInit(DisplayDriverType);
                self.display_dev = DisplayType.init(&self.display_driver);
                self.init_display = true;
            }

            if (HasMic) {
                self.mic_driver = try driverInit(MicDriverType);
                self.mic_dev = MicType.init(&self.mic_driver);
                self.init_mic = true;
            }

            if (HasSpeaker) {
                self.speaker_driver = try driverInit(SpeakerDriverType);
                self.speaker_dev = SpeakerType.init(&self.speaker_driver);
                self.init_speaker = true;
            }

            if (HasTempSensor) {
                self.temp_sensor_driver = try driverInit(TempSensorDriverType);
                self.temp_sensor_dev = TempSensorType.init(&self.temp_sensor_driver);
                self.init_temp_sensor = true;
            }

            if (HasImu) {
                self.imu_driver = try driverInit(ImuDriverType);
                self.imu_dev = ImuType.init(&self.imu_driver);
                self.init_imu = true;
            }

            if (HasGpio) {
                self.gpio_driver = try driverInit(GpioDriverType);
                self.gpio_dev = GpioType.init(&self.gpio_driver);
                self.init_gpio = true;
            }

            if (HasAdc) {
                self.adc_driver = try driverInit(AdcDriverType);
                self.adc_dev = AdcType.init(&self.adc_driver);
                self.init_adc = true;
            }

            if (HasPwm) {
                self.pwm_driver = try driverInit(PwmDriverType);
                self.pwm_dev = PwmType.init(&self.pwm_driver);
                self.init_pwm = true;
            }

            if (HasI2c) {
                self.i2c_driver = try driverInit(I2cDriverType);
                self.i2c_dev = I2cType.init(&self.i2c_driver);
                self.init_i2c = true;
            }

            if (HasSpi) {
                self.spi_driver = try driverInit(SpiDriverType);
                self.spi_dev = SpiType.init(&self.spi_driver);
                self.init_spi = true;
            }

            if (HasUart) {
                self.uart_driver = try driverInit(UartDriverType);
                self.uart_dev = UartType.init(&self.uart_driver);
                self.init_uart = true;
            }

            if (HasWifi) {
                self.wifi_driver = try driverInit(WifiDriverType);
                self.wifi_dev = WifiType.init(&self.wifi_driver);
                self.init_wifi = true;
            }

            if (HasBle) {
                self.ble_driver = try driverInit(BleDriverType);
                self.ble_dev = BleType.init(&self.ble_driver);
                self.init_ble = true;
            }

            if (HasHci) {
                self.hci_driver = try driverInit(HciDriverType);
                self.hci_dev = HciType.init(&self.hci_driver);
                self.init_hci = true;
            }

            if (HasKvs) {
                self.kvs_driver = try driverInit(KvsDriverType);
                self.kvs_dev = KvsType.init(&self.kvs_driver);
                self.init_kvs = true;
            }

            if (HasMotion) {
                self.motion_driver = try driverInit(MotionDriverType);
                self.motion_dev = MotionType.init(&self.motion_driver);
                self.init_motion = true;
            }
        }

        pub fn deinit(self: *Self) void {
            if (HasMotion and self.init_motion) {
                driverDeinit(MotionDriverType, &self.motion_driver);
                self.init_motion = false;
            }
            if (HasKvs and self.init_kvs) {
                driverDeinit(KvsDriverType, &self.kvs_driver);
                self.init_kvs = false;
            }
            if (HasHci and self.init_hci) {
                driverDeinit(HciDriverType, &self.hci_driver);
                self.init_hci = false;
            }
            if (HasBle and self.init_ble) {
                driverDeinit(BleDriverType, &self.ble_driver);
                self.init_ble = false;
            }
            if (HasWifi and self.init_wifi) {
                driverDeinit(WifiDriverType, &self.wifi_driver);
                self.init_wifi = false;
            }
            if (HasUart and self.init_uart) {
                driverDeinit(UartDriverType, &self.uart_driver);
                self.init_uart = false;
            }
            if (HasSpi and self.init_spi) {
                driverDeinit(SpiDriverType, &self.spi_driver);
                self.init_spi = false;
            }
            if (HasI2c and self.init_i2c) {
                driverDeinit(I2cDriverType, &self.i2c_driver);
                self.init_i2c = false;
            }
            if (HasPwm and self.init_pwm) {
                driverDeinit(PwmDriverType, &self.pwm_driver);
                self.init_pwm = false;
            }
            if (HasAdc and self.init_adc) {
                driverDeinit(AdcDriverType, &self.adc_driver);
                self.init_adc = false;
            }
            if (HasGpio and self.init_gpio) {
                driverDeinit(GpioDriverType, &self.gpio_driver);
                self.init_gpio = false;
            }
            if (HasImu and self.init_imu) {
                driverDeinit(ImuDriverType, &self.imu_driver);
                self.init_imu = false;
            }
            if (HasTempSensor and self.init_temp_sensor) {
                driverDeinit(TempSensorDriverType, &self.temp_sensor_driver);
                self.init_temp_sensor = false;
            }
            if (HasSpeaker and self.init_speaker) {
                driverDeinit(SpeakerDriverType, &self.speaker_driver);
                self.init_speaker = false;
            }
            if (HasMic and self.init_mic) {
                driverDeinit(MicDriverType, &self.mic_driver);
                self.init_mic = false;
            }
            if (HasDisplay and self.init_display) {
                driverDeinit(DisplayDriverType, &self.display_driver);
                self.init_display = false;
            }
            if (HasLedStrip and self.init_led_strip) {
                if (comptime has_led_strip_clear) {
                    self.led_strip_dev.clear();
                }
                driverDeinit(LedStripDriverType, &self.led_strip_driver);
                self.init_led_strip = false;
            }
            if (HasLed and self.init_led) {
                if (comptime has_led_off) {
                    self.led_dev.off();
                }
                driverDeinit(LedDriverType, &self.led_driver);
                self.init_led = false;
            }
            if (HasButton and self.init_button) {
                driverDeinit(ButtonDriverType, &self.button_driver);
                self.init_button = false;
            }
            if (self.init_rtc) {
                driverDeinit(RtcDriverType, &self.rtc_driver);
                self.init_rtc = false;
            }
            if (self.queue_inited) {
                self.events.deinit();
                self.queue_inited = false;
            }
        }

        pub fn sendEvent(self: *Self, event: EventType) bool {
            return self.events.trySend(event);
        }

        pub fn hasEvents(self: *const Self) bool {
            return !self.events.isEmpty();
        }

        pub fn nextEvent(self: *Self) ?EventType {
            if (UsesDefaultEvent) {
                self.pollPeripherals();
            }
            return self.events.tryReceive();
        }

        pub fn getEventQueue(self: *Self) *EventQueueType {
            return &self.events;
        }

        pub fn uptime(self: *Self) u64 {
            return self.rtc_dev.uptime();
        }

        pub fn now(self: *Self) ?rtc_mod.Timestamp {
            if (comptime has_rtc_now) {
                return self.rtc_dev.now();
            }
            return null;
        }

        fn pollPeripherals(self: *Self) void {
            if (HasButton and self.init_button) {
                self.pollOne("button", ButtonType, &self.button_dev);
            }
            if (HasWifi and self.init_wifi) {
                self.pollOne("wifi", WifiType, &self.wifi_dev);
            }
            if (HasBle and self.init_ble) {
                self.pollOne("ble", BleType, &self.ble_dev);
            }
            if (HasMotion and self.init_motion) {
                self.pollOne("motion", MotionType, &self.motion_dev);
            }
        }

        fn pollOne(self: *Self, comptime tag: []const u8, comptime PeripheralType: type, peripheral: *PeripheralType) void {
            const style = comptime getPollStyle(PeripheralType);
            switch (style) {
                .poll_event_noarg => {
                    if (peripheral.pollEvent()) |ev| {
                        _ = self.events.trySend(@unionInit(EventType, tag, ev));
                    }
                },
                .poll_event_noarg_err => {
                    if (peripheral.pollEvent() catch null) |ev| {
                        _ = self.events.trySend(@unionInit(EventType, tag, ev));
                    }
                },
                .poll_i32 => {
                    if (peripheral.poll(0)) |ev| {
                        _ = self.events.trySend(@unionInit(EventType, tag, ev));
                    }
                },
                .poll_i32_err => {
                    if (peripheral.poll(0) catch null) |ev| {
                        _ = self.events.trySend(@unionInit(EventType, tag, ev));
                    }
                },
                .poll_u64 => {
                    if (peripheral.poll(self.uptime())) |ev| {
                        _ = self.events.trySend(@unionInit(EventType, tag, ev));
                    }
                },
                .poll_u64_err => {
                    if (peripheral.poll(self.uptime()) catch null) |ev| {
                        _ = self.events.trySend(@unionInit(EventType, tag, ev));
                    }
                },
                .none => {},
            }
        }
    };
}

pub fn from(comptime spec: type) type {
    return Board(spec);
}

// ============================================================================
// Tests
// ============================================================================

test "SimpleQueue basic operations" {
    var q = SimpleQueue(u32, 4).init();

    try std.testing.expect(q.isEmpty());
    try std.testing.expect(q.trySend(1));
    try std.testing.expect(q.trySend(2));
    try std.testing.expectEqual(@as(usize, 2), q.count());
    try std.testing.expectEqual(@as(?u32, 1), q.tryReceive());
    try std.testing.expectEqual(@as(?u32, 2), q.tryReceive());
    try std.testing.expectEqual(@as(?u32, null), q.tryReceive());
}

test "Board init/deinit and ble event polling" {
    const rtc_driver = struct {
        pub fn init() !@This() {
            return .{};
        }
        pub fn deinit(_: *@This()) void {}
        pub fn uptime(_: *@This()) u64 {
            return 123;
        }
        pub fn nowMs(_: *@This()) ?i64 {
            return 1_769_427_296_987;
        }
    };

    const rtc_spec = struct {
        pub const Driver = rtc_driver;
        pub const meta = .{ .id = "rtc.test" };
    };
    const Rtc = rtc_mod.reader.from(rtc_spec);

    const led_mod = @import("led.zig");
    const led_driver = struct {
        duty: u16 = 0,
        pub fn init() !@This() {
            return .{};
        }
        pub fn deinit(_: *@This()) void {}
        pub fn setDuty(self: *@This(), duty: u16) void {
            self.duty = duty;
        }
        pub fn getDuty(self: *const @This()) u16 {
            return self.duty;
        }
        pub fn fade(self: *@This(), duty: u16, _: u32) void {
            self.duty = duty;
        }
    };
    const led_spec = struct {
        pub const Driver = led_driver;
        pub const meta = .{ .id = "led.test" };
    };
    const Led = led_mod.from(led_spec);

    const ble_mod = @import("ble.zig");
    const ble_driver = struct {
        state: ble_mod.State = .idle,
        pending: ?ble_mod.BleEvent = null,

        pub fn init() !@This() {
            return .{};
        }
        pub fn deinit(_: *@This()) void {}
        pub fn start(self: *@This()) ble_mod.Error!void {
            self.state = .idle;
        }
        pub fn stop(self: *@This()) void {
            self.state = .uninitialized;
        }
        pub fn startAdvertising(self: *@This(), _: ble_mod.AdvConfig) ble_mod.Error!void {
            self.state = .advertising;
        }
        pub fn stopAdvertising(self: *@This()) ble_mod.Error!void {
            self.state = .idle;
        }
        pub fn poll(self: *@This(), _: i32) ?ble_mod.BleEvent {
            const ev = self.pending;
            self.pending = null;
            return ev;
        }
        pub fn getState(self: *const @This()) ble_mod.State {
            return self.state;
        }
        pub fn disconnect(_: *@This(), _: u16, _: u8) ble_mod.Error!void {}
        pub fn notify(_: *@This(), _: u16, _: u16, _: []const u8) void {}
        pub fn indicate(_: *@This(), _: u16, _: u16, _: []const u8) void {}
        pub fn getConnHandle(_: *const @This()) ?u16 {
            return 1;
        }
    };
    const ble_spec = struct {
        pub const Driver = ble_driver;
        pub const meta = .{ .id = "ble.test" };
    };
    const Ble = ble_mod.from(ble_spec);

    const board_spec = struct {
        pub const meta = .{ .id = "board.test" };
        pub const rtc = Rtc;
        pub const led = Led;
        pub const ble = Ble;
    };

    const TestBoard = Board(board_spec);

    var board: TestBoard = undefined;
    try board.init();
    defer board.deinit();

    // 注入一个 BLE 事件，验证 nextEvent 自动轮询
    board.ble_driver.pending = .{ .advertising_started = {} };

    const ev = board.nextEvent() orelse return error.ExpectedEvent;
    switch (ev) {
        .ble => |b| {
            switch (b) {
                .advertising_started => {},
                else => return error.UnexpectedEvent,
            }
        },
        else => return error.UnexpectedEvent,
    }

    try std.testing.expectEqual(@as(u64, 123), board.uptime());
    const now_ts = board.now() orelse return error.ExpectedNow;
    try std.testing.expectEqual(@as(i64, 1_769_427_296), now_ts.toEpoch());
}

test "Board motion event polling" {
    const rtc_driver = struct {
        ticks: u64 = 0,

        pub fn init() !@This() {
            return .{};
        }
        pub fn deinit(_: *@This()) void {}
        pub fn uptime(self: *@This()) u64 {
            self.ticks += 50;
            return self.ticks;
        }
        pub fn nowMs(_: *@This()) ?i64 {
            return null;
        }
    };

    const rtc_spec = struct {
        pub const Driver = rtc_driver;
        pub const meta = .{ .id = "rtc.motion" };
    };
    const Rtc = rtc_mod.reader.from(rtc_spec);

    const imu_mod = @import("imu.zig");
    const motion_mod = @import("motion.zig");
    const motion_driver = struct {
        samples: [4]imu_mod.AccelData = .{
            .{ .x = 0, .y = 0, .z = 1 },
            .{ .x = 1.5, .y = 0, .z = 1 },
            .{ .x = -1.5, .y = 0, .z = 1 },
            .{ .x = 1.6, .y = 0, .z = 1 },
        },
        idx: usize = 0,

        pub fn init() !@This() {
            return .{};
        }
        pub fn deinit(_: *@This()) void {}
        pub fn readAccel(self: *@This()) motion_mod.Error!imu_mod.AccelData {
            const i = @min(self.idx, self.samples.len - 1);
            const s = self.samples[i];
            if (self.idx + 1 < self.samples.len) self.idx += 1;
            return s;
        }
        pub fn readGyro(_: *@This()) motion_mod.Error!imu_mod.GyroData {
            return .{ .x = 0, .y = 0, .z = 0 };
        }
    };

    const Motion = motion_mod.from(struct {
        pub const Driver = motion_driver;
        pub const meta = .{ .id = "motion.board" };
        pub const thresholds = motion_mod.Thresholds{
            .shake_delta_g = 1.0,
            .shake_window_ms = 300,
            .shake_min_pulses = 3,
            .tap_peak_g = 10,
            .tilt_threshold_deg = 179,
            .freefall_threshold_g = 0.05,
        };
    });

    const board_spec = struct {
        pub const meta = .{ .id = "board.motion" };
        pub const rtc = Rtc;
        pub const motion = Motion;
    };

    const TestBoard = Board(board_spec);
    var board: TestBoard = undefined;
    try board.init();
    defer board.deinit();

    var saw_motion = false;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        if (board.nextEvent()) |ev| {
            switch (ev) {
                .motion => |m| {
                    switch (m.action) {
                        .shake => saw_motion = true,
                        else => {},
                    }
                },
                else => {},
            }
        }
    }

    try std.testing.expect(saw_motion);
}

const std = @import("std");
const modules = @import("sdkconfig_modules");
const partition = @import("idf_partition");
const esp = @import("esp");
const heap = @import("heap");
const hal = @import("embed/hal");
const runtime = @import("embed/runtime");
const runtime_esp = @import("runtime_esp");
const hal_esp = @import("hal_esp");
const event = @import("embed/pkg/event");

// ============================================================================
// SDKconfig
// ============================================================================

pub const config = .{
    .core = modules.esp_system_config.withDefaultConfig(.{
        .main_task_stack_size = 16384,
    }),
    .esp_misc = modules.esp_misc_config.withDefaultConfig(.{
        .esp_main_task_stack_size = 16384,
    }),
    .freertos = modules.freertos_config.default,
    .app_metadata = modules.app_metadata_config.default,
    .app_trace = modules.app_trace_config.default,
    .bootloader = modules.bootloader_config.default,
    .bt = modules.bt_config.default,
    .console = modules.console_config.default,
    .efuse = modules.efuse_config.default,
    .esp_adc = modules.esp_adc_config.default,
    .esp_coex = modules.esp_coex_config.default,
    .esp_driver_gdma = modules.esp_driver_gdma_config.default,
    .esp_driver_gpio = modules.esp_driver_gpio_config.default,
    .esp_driver_gptimer = modules.esp_driver_gptimer_config.default,
    .esp_driver_i2c = modules.esp_driver_i2c_config.default,
    .esp_driver_i2s = modules.esp_driver_i2s_config.default,
    .esp_driver_ledc = modules.esp_driver_ledc_config.default,
    .esp_driver_mcpwm = modules.esp_driver_mcpwm_config.default,
    .esp_driver_pcnt = modules.esp_driver_pcnt_config.default,
    .esp_driver_rmt = modules.esp_driver_rmt_config.default,
    .esp_driver_sdm = modules.esp_driver_sdm_config.default,
    .esp_driver_spi = modules.esp_driver_spi_config.default,
    .esp_driver_touch_sens = modules.esp_driver_touch_sens_config.default,
    .esp_driver_tsens = modules.esp_driver_tsens_config.default,
    .esp_driver_twai = modules.esp_driver_twai_config.default,
    .esp_driver_uart = modules.esp_driver_uart_config.default,
    .esp_eth = modules.esp_eth_config.default,
    .esp_event = modules.esp_event_config.default,
    .esp_gdbstub = modules.esp_gdbstub_config.default,
    .esp_http_client = modules.esp_http_client_config.default,
    .esp_http_server = modules.esp_http_server_config.default,
    .esp_https_ota = modules.esp_https_ota_config.default,
    .esp_https_server = modules.esp_https_server_config.default,
    .esp_hw_support = modules.esp_hw_support_config.default,
    .esp_lcd = modules.esp_lcd_config.default,
    .esp_mm = modules.esp_mm_config.default,
    .esp_netif = modules.esp_netif_config.default,
    .esp_phy = modules.esp_phy_config.default,
    .esp_pm = modules.esp_pm_config.default,
    .esp_psram = modules.esp_psram_config.withDefaultConfig(.{
        .spiram = true,
        .spiram_mode_oct = true,
        .spiram_speed_80m = true,
    }),
    .esp_security = modules.esp_security_config.default,
    .esp_timer = modules.esp_timer_config.default,
    .esp_wifi = modules.esp_wifi_config.default,
    .espcoredump = modules.espcoredump_config.default,
    .esptool_py = modules.esptool_py_config.default,
    .fatfs = modules.fatfs_config.default,
    .hal = modules.hal_config.default,
    .heap = modules.heap_config.default,
    .idf_build_system = modules.idf_build_system_config.default,
    .log = modules.log_config.default,
    .lwip = modules.lwip_config.default,
    .mbedtls = modules.mbedtls_config.default,
    .mqtt = modules.mqtt_config.default,
    .newlib = modules.newlib_config.default,
    .nvs_flash = modules.nvs_flash_config.default,
    .openthread = modules.openthread_config.default,
    .partition_table_cfg = modules.partition_table_config.default,
    .pthread = modules.pthread_config.default,
    .soc = modules.soc_config.default,
    .spi_flash = modules.spi_flash_config.default,
    .spiffs = modules.spiffs_config.default,
    .target_soc = modules.target_soc_config.withDefaultConfig(.{
        .esp32s3_spiram_support = true,
    }),
    .tcp_transport = modules.tcp_transport_config.default,
    .toolchain = modules.toolchain_config.default,
    .ulp = modules.ulp_config.default,
    .unity = modules.unity_config.default,
    .usb = modules.usb_config.default,
    .vfs = modules.vfs_config.default,
    .wear_levelling = modules.wear_levelling_config.default,
    .wpa_supplicant = modules.wpa_supplicant_config.default,
    .board = .{
        .name = @as([]const u8, "board.esp32s3_korvo2"),
        .chip = @as([]const u8, "esp32s3"),
        .target_arch = @as([]const u8, "xtensa"),
        .target_arch_config_flag = @as([]const u8, "CONFIG_IDF_TARGET_ARCH_XTENSA"),
        .target_config_flag = @as([]const u8, "CONFIG_IDF_TARGET_ESP32S3"),
    },
    .partition_table = partition.default_table,
};

// ============================================================================
// Korvo-2 hardware parameters
// ============================================================================

const adc_button_channel: u8 = 6;

const i2s_bclk: u8 = 9;
const i2s_ws: u8 = 45;
const i2s_din: u8 = 10;
const i2s_dout: u8 = 8;
const i2s_mclk: u8 = 16;

const i2c_sda: u8 = 17;
const i2c_scl: u8 = 18;

const pa_gpio: u8 = 48;

// ============================================================================
// hw — the contract that firmware app.zig consumes
// ============================================================================

const InnerAudioDriver = hal_esp.AudioSystemEs7210Es8311.DriverType;

pub const hw = struct {
    pub const name: []const u8 = "esp32s3_korvo2";

    pub const allocator = struct {
        pub const user = heap.psram;
        pub const system = heap.dram;
        pub const default = heap.default;
    };

    pub const thread = struct {
        pub const Thread = runtime_esp.Thread;
        pub const user_defaults: runtime.thread.SpawnConfig = .{
            .allocator = heap.psram,
            .priority = 3,
            .name = "user",
            .core_id = 0,
        };
        pub const system_defaults: runtime.thread.SpawnConfig = .{
            .allocator = heap.dram,
            .priority = 5,
            .name = "sys",
        };
        pub const default_defaults: runtime.thread.SpawnConfig = .{
            .allocator = heap.default,
            .priority = 5,
            .name = "zig-task",
        };
    };

    pub const sync = struct {
        pub const Mutex = runtime_esp.Mutex;
        pub const Condition = runtime_esp.Condition;
    };

    pub const log = runtime_esp.Log;
    pub const time = runtime_esp.Time;
    pub const io = runtime_esp.IO;

    // Korvo-2 V3: 6 ADC buttons on ADC1 CH4, 12dB atten, 12-bit.
    // mV ranges calibrated from raw values (raw * 3300 / 4095).
    pub const adc_button_config = event.button.AdcButtonConfig{
        .ranges = &.{
            .{ .id = "vol_up", .min_mv = 200, .max_mv = 483 },
            .{ .id = "vol_down", .min_mv = 604, .max_mv = 886 },
            .{ .id = "set", .min_mv = 894, .max_mv = 1208 },
            .{ .id = "play", .min_mv = 1216, .max_mv = 1692 },
            .{ .id = "mute", .min_mv = 1700, .max_mv = 2054 },
            .{ .id = "rec", .min_mv = 2135, .max_mv = 2497 },
        },
        .adc_channel = adc_button_channel,
        .poll_interval_ms = 20,
        .debounce_samples = 3,
    };

    pub const rtc_spec = struct {
        pub const Driver = hal_esp.RtcReader.DriverType;
        pub const meta = .{ .id = "rtc.korvo2" };
    };

    pub const adc_spec = struct {
        pub const Driver = struct {
            inner: hal_esp.Adc.DriverType,

            const Self = @This();

            pub fn init() !Self {
                return .{ .inner = try hal_esp.Adc.DriverType.init() };
            }

            pub fn read(self: *Self, channel: u8) hal.adc.Error!u16 {
                return self.inner.read(channel);
            }

            pub fn readMv(self: *Self, channel: u8) hal.adc.Error!u16 {
                return self.inner.readMv(channel);
            }
        };
        pub const meta = .{ .id = "adc.korvo2" };
    };

    pub const audio_system_spec = struct {
        const I2cDriver = hal_esp.I2c.DriverType;
        const I2sDriver = hal_esp.I2s.DriverType;

        const audio_codec_cfg = hal_esp.audio_system_config.Config{
            .mics = .{
                .{ .enabled = true, .gain_db = 24 },
                .{ .enabled = true, .gain_db = 24 },
                .{ .enabled = true, .gain_db = 0 },
                .{},
            },
            .ref = .{ .hw = .{ .channel = 2 } },
            .frame_samples = 160,
            .spk_duplicate_mono = true,
        };

        pub const Driver = struct {
            inner: InnerAudioDriver,
            i2c_heap: *I2cDriver,
            i2s_heap: *I2sDriver,

            const Self = @This();

            pub fn init() hal.audio_system.Error!Self {
                const alloc = heap.dram;

                const i2c_ptr = alloc.create(I2cDriver) catch return error.AudioSystemError;
                errdefer alloc.destroy(i2c_ptr);
                i2c_ptr.* = I2cDriver.initMaster(.{
                    .sda = i2c_sda,
                    .scl = i2c_scl,
                }) catch return error.AudioSystemError;

                const i2s_ptr = alloc.create(I2sDriver) catch return error.AudioSystemError;
                errdefer alloc.destroy(i2s_ptr);
                i2s_ptr.* = I2sDriver.initBus(.{
                    .bclk = i2s_bclk,
                    .ws = i2s_ws,
                    .mclk = i2s_mclk,
                    .sample_rate_hz = 16_000,
                    .bits_per_sample = .bits16,
                    .slot_mode = .stereo,
                }) catch return error.AudioSystemError;
                errdefer i2s_ptr.deinitBus();

                const rx_handle = i2s_ptr.registerEndpoint(.{
                    .direction = .rx,
                    .data_pin = i2s_din,
                }) catch return error.AudioSystemError;

                const tx_handle = i2s_ptr.registerEndpoint(.{
                    .direction = .tx,
                    .data_pin = i2s_dout,
                }) catch return error.AudioSystemError;

                const inner = InnerAudioDriver.init(
                    i2c_ptr,
                    i2s_ptr,
                    rx_handle,
                    tx_handle,
                    alloc,
                    audio_codec_cfg,
                ) catch return error.AudioSystemError;

                return .{
                    .inner = inner,
                    .i2c_heap = i2c_ptr,
                    .i2s_heap = i2s_ptr,
                };
            }

            pub fn deinit(self: *Self) void {
                const alloc = heap.dram;
                self.inner.deinit();
                self.i2s_heap.deinitBus();
                alloc.destroy(self.i2s_heap);
                alloc.destroy(self.i2c_heap);
            }

            pub fn readFrame(self: *Self) hal.audio_system.Error!hal.audio_system.Frame(4) {
                return self.inner.readFrame();
            }

            pub fn writeSpk(self: *Self, buffer: []const i16) hal.audio_system.Error!usize {
                return self.inner.writeSpk(buffer);
            }

            pub fn setMicGain(self: *Self, mic_index: u8, gain_db: i8) hal.audio_system.Error!void {
                return self.inner.setMicGain(mic_index, gain_db);
            }

            pub fn setSpkGain(self: *Self, gain_db: i8) hal.audio_system.Error!void {
                return self.inner.setSpkGain(gain_db);
            }

            pub fn start(self: *Self) hal.audio_system.Error!void {
                return self.inner.start();
            }

            pub fn stop(self: *Self) hal.audio_system.Error!void {
                return self.inner.stop();
            }
        };
        pub const meta = .{ .id = "audio_system.korvo2" };
        pub const config = hal.audio_system.Config{ .sample_rate = 16000, .mic_count = 4 };
    };
};

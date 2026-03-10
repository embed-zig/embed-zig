//! Hardware definition for 立创实战派 ESP32-S3 (LiChuang SZP).
//! Separated from the board config to avoid @import("esp") during sdkconfig generation.

const esp_pkg = @import("esp");
const esp_hal = esp_pkg.hal;
const i2c = esp_pkg.component.esp_driver_i2c;
const ledc = esp_pkg.component.esp_driver_ledc.ledc;
const spiffs = esp_pkg.component.spiffs.spiffs;
const hal = esp_pkg.embed.hal;

const lcd_mosi: i32 = 40;
const lcd_clk: i32 = 41;
const lcd_dc: i32 = 39;
const lcd_backlight: i32 = 42;
const lcd_width: u16 = 320;
const lcd_height: u16 = 240;
const lcd_cs: i32 = -1;

const i2c_sda: i32 = 1;
const i2c_scl: i32 = 2;
const i2c_port: i32 = 0;
const i2c_freq: u32 = 100_000;

const pca9557_addr: u8 = 0x19;
const pca9557_output_reg: u8 = 0x01;
const pca9557_config_reg: u8 = 0x03;
const pca9557_init_output: u8 = 0x05;
const pca9557_init_config: u8 = 0xF8;
const pca9557_cs_bit: u8 = 0x01;

pub const name: []const u8 = "esp32s3_szp";

pub const allocator = struct {
    pub const user = esp_pkg.component.heap.psram;
    pub const system = esp_pkg.component.heap.dram;
    pub const default = esp_pkg.component.heap.default;
};

pub const log = esp_pkg.runtime.Log;
pub const time = esp_pkg.runtime.Time;
pub const fs = esp_pkg.runtime.Fs;

pub fn mountAssets() !void {
    return spiffs.mount("font_store", "/assets", 5, false);
}

pub fn unmountAssets() void {
    spiffs.unmount("font_store");
}

pub fn printRuntimeStats() void {
    const heap = struct {
        const MALLOC_CAP_INTERNAL = 1 << 11;
        const MALLOC_CAP_SPIRAM = 1 << 10;
        extern fn heap_caps_get_total_size(caps: u32) usize;
        extern fn heap_caps_get_free_size(caps: u32) usize;
    };

    const internal_total = heap.heap_caps_get_total_size(heap.MALLOC_CAP_INTERNAL);
    const internal_free = heap.heap_caps_get_free_size(heap.MALLOC_CAP_INTERNAL);
    const psram_total = heap.heap_caps_get_total_size(heap.MALLOC_CAP_SPIRAM);
    const psram_free = heap.heap_caps_get_free_size(heap.MALLOC_CAP_SPIRAM);

    const printf = struct {
        extern fn esp_rom_printf(fmt: [*:0]const u8, ...) c_int;
    }.esp_rom_printf;

    _ = printf("[mem] Internal: %uK used / %uK total\n", @as(c_uint, @intCast((internal_total - internal_free) / 1024)), @as(c_uint, @intCast(internal_total / 1024)));
    _ = printf("[mem] PSRAM:    %uK used / %uK total\n", @as(c_uint, @intCast((psram_total - psram_free) / 1024)), @as(c_uint, @intCast(psram_total / 1024)));
    _ = printf("[mem] Internal free: %uK  PSRAM free: %uK\n", @as(c_uint, @intCast(internal_free / 1024)), @as(c_uint, @intCast(psram_free / 1024)));
}

pub const rtc_spec = struct {
    pub const Driver = esp_hal.RtcReader.DriverType;
    pub const meta = .{ .id = "rtc.szp" };
};

var g_i2c_bus: i2c.I2cMaster = undefined;
var g_i2c_ready: bool = false;

fn pca9557Write(reg: u8, data: u8) void {
    if (!g_i2c_ready) return;
    g_i2c_bus.write(pca9557_addr, &.{ reg, data }, 100) catch {};
}

fn pca9557SetCS(level: bool) void {
    if (!g_i2c_ready) return;
    var read_buf: [1]u8 = undefined;
    g_i2c_bus.writeRead(pca9557_addr, &.{pca9557_output_reg}, &read_buf, 100) catch return;
    var output = read_buf[0];
    if (level) {
        output |= pca9557_cs_bit;
    } else {
        output &= ~pca9557_cs_bit;
    }
    pca9557Write(pca9557_output_reg, output);
}

fn initI2cAndExpander() !void {
    g_i2c_bus = i2c.I2cMaster.init(.{
        .port = i2c_port,
        .sda = i2c_sda,
        .scl = i2c_scl,
        .freq_hz = i2c_freq,
    }) catch return error.DisplayError;
    g_i2c_ready = true;
    pca9557Write(pca9557_output_reg, pca9557_init_output);
    pca9557Write(pca9557_config_reg, pca9557_init_config);
}

fn enableBacklight() void {
    ledc.configureTimer(.{
        .speed_mode = 0,
        .timer_num = 0,
        .duty_resolution_bits = 10,
        .freq_hz = 5000,
        .clk_cfg = ledc.clk_cfg_auto,
    }) catch return;
    ledc.configureChannel(.{
        .gpio = lcd_backlight,
        .speed_mode = 0,
        .channel = 0,
        .timer_num = 0,
        .invert = true,
    }) catch return;
    ledc.setDutyPercentWithResolution(0, 0, 10, 100) catch {};
}

pub const display_spec = struct {
    pub const Driver = struct {
        inner: esp_hal.Display.DriverType,

        const Self = @This();

        pub fn init() hal.display.Error!Self {
            initI2cAndExpander() catch return error.DisplayError;

            const inner = esp_hal.Display.DriverType.init(.{
                .panel = .st7789,
                .width = lcd_width,
                .height = lcd_height,
                .host_id = 2,
                .sclk = lcd_clk,
                .mosi = lcd_mosi,
                .miso = -1,
                .cs = lcd_cs,
                .dc = lcd_dc,
                .reset = -1,
                .pclk_hz = 80_000_000,
                .spi_mode = 2,
                .max_transfer_bytes = @as(usize, lcd_width) * @as(usize, lcd_height) * 2,
                .dma_channel = 3,
                .invert_color = true,
                .swap_xy = true,
                .mirror_x = true,
                .mirror_y = false,
                .data_endian = .little,
                .pre_init_hook = &struct {
                    fn hook() void {
                        pca9557SetCS(false);
                    }
                }.hook,
            }) catch return error.DisplayError;

            enableBacklight();

            return .{ .inner = inner };
        }

        pub fn deinit(self: *Self) void {
            self.inner.deinit();
        }

        pub fn width(self: *const Self) u16 {
            return self.inner.width();
        }

        pub fn height(self: *const Self) u16 {
            return self.inner.height();
        }

        pub fn setDisplayEnabled(self: *Self, enabled: bool) hal.display.Error!void {
            return self.inner.setDisplayEnabled(enabled);
        }

        pub fn sleep(self: *Self, enabled: bool) hal.display.Error!void {
            return self.inner.sleep(enabled);
        }

        pub fn drawBitmap(self: *Self, x: u16, y: u16, w: u16, h: u16, data: []const hal.display.Color565) hal.display.Error!void {
            return self.inner.drawBitmap(x, y, w, h, data);
        }
    };
    pub const meta = .{ .id = "display.szp_st7789" };
};

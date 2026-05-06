const embed = @import("embed");
const esp = @import("esp");
const Display = @import("Display.zig");
const player_ui = @import("ui/player.zig");

const Es7210 = embed.drivers.audio.Es7210;
const Es8311 = embed.drivers.audio.Es8311;
const Pca9557 = embed.drivers.gpio.Pca9557;
const log = esp.grt.std.log.scoped(.chant_board);

const i2c_port = 0;
const i2c_sda_gpio = 1;
const i2c_scl_gpio = 2;
const i2c_frequency_hz = 100_000;
const audio_sample_rate = 16_000;
const es7210_address = @intFromEnum(Es7210.Address.ad1_ad0_01);
const es8311_address = @intFromEnum(Es8311.Address.ad0_low);
const pca9557_address = 0x19;
const pca_lcd_cs_pin = Pca9557.Pin.pin0;
const pca_pa_en_pin = Pca9557.Pin.pin1;
const pca_dvp_pwdn_pin = Pca9557.Pin.pin2;
const pca_output_mask = pca_lcd_cs_pin.mask() | pca_pa_en_pin.mask() | pca_dvp_pwdn_pin.mask();
const pca_initial_output = pca_lcd_cs_pin.mask() | pca_dvp_pwdn_pin.mask();
const ft5x06_address = 0x38;
const touch_width: u16 = 320;
const touch_height: u16 = 240;
pub const default_volume: u8 = 0xb0;
const esp_ok: c_int = 0;
const esp_fail: c_int = -1;

var board_i2c_bus = esp.embed.I2c.MasterBus.init(.{
    .port = i2c_port,
    .sda_io_num = i2c_sda_gpio,
    .scl_io_num = i2c_scl_gpio,
    .scl_speed_hz = i2c_frequency_hz,
});
var pca9557: ?Pca9557 = null;
var audio_adc: ?Es7210 = null;
var audio_codec: ?Es8311 = null;
var audio_volume: u8 = default_volume;
var audio_ready = false;

pub const Track = player_ui.Track;
pub const Mode = player_ui.Mode;
pub const DisplayAction = player_ui.Action;

pub const TouchPoint = struct {
    x: u16,
    y: u16,
};

extern fn szp_board_init() c_int;
extern fn szp_storage_init_nvs() c_int;
extern fn szp_storage_mount() c_int;
extern fn szp_storage_info(total: *usize, used: *usize) c_int;
extern fn szp_storage_unmount() c_int;
extern fn szp_audio_init() c_int;
extern fn szp_audio_set_pa(enabled: bool) c_int;
extern fn szp_audio_write_i16(pcm: [*]const i16, sample_count: usize) c_int;
extern fn szp_audio_play_test_tone(frequency_hz: u32, duration_ms: u32) c_int;
extern fn szp_audio_mic_start() c_int;
extern fn szp_audio_mic_process_frame() c_int;
extern fn szp_audio_mic_stop() c_int;
extern fn szp_button_init() c_int;
extern fn szp_button_read_raw() bool;

pub fn initNvs() !void {
    try check("szp_storage_init_nvs", szp_storage_init_nvs());
}

pub fn mountStorage() !void {
    try check("szp_storage_mount", szp_storage_mount());
}

pub fn unmountStorage() void {
    check("szp_storage_unmount", szp_storage_unmount()) catch |err| {
        log.warn("storage unmount failed: {s}", .{@errorName(err)});
    };
}

pub fn storageInfo() !struct { total: usize, used: usize } {
    var total: usize = 0;
    var used: usize = 0;
    try check("szp_storage_info", szp_storage_info(&total, &used));
    return .{ .total = total, .used = used };
}

pub fn initBoard() !void {
    try check("szp_board_init", szp_board_init());
    try initDisplay();
    try initTouch();
}

pub fn initAudio() !void {
    if (audio_ready) return;

    try check("szp_audio_init", szp_audio_init());
    try board_i2c_bus.open();

    const i2c = try board_i2c_bus.device(es8311_address);
    var codec = Es8311.init(i2c, .{
        .address = es8311_address,
        .codec_mode = .dac_only,
    });

    try codec.open();
    const chip_id = try codec.readChipId();
    log.info("es8311 chip_id=0x{x}", .{chip_id});
    try codec.setSampleRate(audio_sample_rate);
    try codec.setBitsPerSample(.@"16bit");
    try codec.setFormat(.i2s);
    try codec.enable(true);
    try codec.setVolume(audio_volume);
    try codec.setMute(false);

    const adc_i2c = try board_i2c_bus.device(es7210_address);
    var adc = Es7210.init(adc_i2c, .{
        .address = es7210_address,
        .mic_select = .{ .mic1 = true, .mic2 = true, .mic3 = true, .mic4 = true },
    });
    try adc.open();
    try adc.enable(true);

    audio_adc = adc;
    audio_codec = codec;
    try check("szp_audio_set_pa", szp_audio_set_pa(true));
    audio_ready = true;
}

pub fn playTestTone(frequency_hz: u32, duration_ms: u32) !void {
    try initAudio();
    try check("szp_audio_play_test_tone", szp_audio_play_test_tone(frequency_hz, duration_ms));
}

pub fn writePcm(samples: []const i16) !void {
    if (samples.len == 0) return;
    try check("szp_audio_write_i16", szp_audio_write_i16(samples.ptr, samples.len));
}

pub fn startMicrophoneStream() !void {
    try initAudio();
    try check("szp_audio_mic_start", szp_audio_mic_start());
}

pub fn processMicrophoneFrame() !void {
    try check("szp_audio_mic_process_frame", szp_audio_mic_process_frame());
}

pub fn stopMicrophoneStream() void {
    check("szp_audio_mic_stop", szp_audio_mic_stop()) catch |err| {
        log.warn("mic stream stop failed: {s}", .{@errorName(err)});
    };
}

pub fn setVolume(volume: u8) !void {
    audio_volume = volume;
    if (audio_codec) |*codec| {
        try codec.setVolume(volume);
    }
}

pub fn initButton() !void {
    try check("szp_button_init", szp_button_init());
}

pub fn buttonPressedRaw() bool {
    return szp_button_read_raw();
}

pub fn pollTouch() !?TouchPoint {
    var points: [1]u8 = .{0};
    try touchRead(0x02, &points);
    const point_count = points[0] & 0x0f;
    if (point_count == 0 or point_count > 5) return null;

    var data: [4]u8 = undefined;
    try touchRead(0x03, &data);

    const raw_x = (@as(u16, data[0] & 0x0f) << 8) | data[1];
    const raw_y = (@as(u16, data[2] & 0x0f) << 8) | data[3];

    // Match the LCD rotation used by the reference board example:
    // swap XY, then mirror X before the swap.
    const x = if (raw_y >= touch_width) touch_width - 1 else raw_y;
    const y = if (raw_x >= touch_height) 0 else touch_height - 1 - raw_x;
    return .{ .x = x, .y = y };
}

pub fn initDisplay() !void {
    try Display.init();
    player_ui.setTouchReader(readTouchForUi);
}

pub fn showTrack(track: Track) !void {
    try showPlayer(track, .music, true, default_volume);
}

pub fn showPlayer(track: Track, mode: Mode, playing: bool, volume: u8) !void {
    try Display.init();
    try player_ui.show(Display.driver(), track, mode, playing, volume);
}

pub fn tickDisplay(elapsed_ms: u32) void {
    player_ui.tick(elapsed_ms);
}

pub fn takeDisplayAction() DisplayAction {
    return player_ui.takeAction();
}

pub export fn szp_i2c_init() c_int {
    board_i2c_bus.open() catch |err| return boardI2cError("szp_i2c_init", err);
    return esp_ok;
}

pub export fn szp_i2c_write_reg(address: u8, reg: u8, value: u8) c_int {
    const i2c_address = checkedI2cAddress(address) catch |err| return boardI2cError("szp_i2c_write_reg", err);
    const i2c = board_i2c_bus.device(i2c_address) catch |err| return boardI2cError("szp_i2c_write_reg", err);
    i2c.write(i2c_address, &.{ reg, value }) catch |err| return boardI2cError("szp_i2c_write_reg", err);
    return esp_ok;
}

pub export fn szp_i2c_read_reg(address: u8, reg: u8, value: ?*u8) c_int {
    const out = value orelse return esp_fail;
    const i2c_address = checkedI2cAddress(address) catch |err| return boardI2cError("szp_i2c_read_reg", err);
    const i2c = board_i2c_bus.device(i2c_address) catch |err| return boardI2cError("szp_i2c_read_reg", err);

    var rx: [1]u8 = undefined;
    i2c.writeRead(i2c_address, &.{reg}, &rx) catch |err| return boardI2cError("szp_i2c_read_reg", err);
    out.* = rx[0];
    return esp_ok;
}

pub export fn szp_pca9557_init() c_int {
    initPca9557() catch |err| return boardI2cError("szp_pca9557_init", err);
    return esp_ok;
}

pub export fn szp_pca9557_set_lcd_cs(high: bool) c_int {
    setPca9557Pin(pca_lcd_cs_pin, high) catch |err| return boardI2cError("szp_pca9557_set_lcd_cs", err);
    return esp_ok;
}

pub export fn szp_pca9557_set_pa(enabled: bool) c_int {
    setPca9557Pin(pca_pa_en_pin, enabled) catch |err| return boardI2cError("szp_pca9557_set_pa", err);
    return esp_ok;
}

fn check(name: []const u8, rc: c_int) !void {
    if (rc == 0) return;
    log.err("{s} failed with rc={d}", .{ name, rc });
    return error.BoardCallFailed;
}

fn checkedI2cAddress(address: u8) !embed.drivers.I2c.Address {
    if (address > 0x7f) return error.InvalidI2cAddress;
    return @intCast(address);
}

fn initPca9557() !void {
    try board_i2c_bus.open();
    const i2c = try board_i2c_bus.device(pca9557_address);
    var driver = Pca9557.init(i2c, pca9557_address);
    try driver.configureMultiple(pca_output_mask, pca_initial_output);
    pca9557 = driver;
}

fn setPca9557Pin(pin: Pca9557.Pin, high: bool) !void {
    const driver = try ensurePca9557();
    try driver.write(pin, if (high) .high else .low);
}

fn ensurePca9557() !*Pca9557 {
    if (pca9557 == null) {
        try initPca9557();
    }
    if (pca9557) |*driver| return driver;
    return error.BoardCallFailed;
}

fn initTouch() !void {
    try touchWrite(0x80, 70);
    try touchWrite(0x81, 60);
    try touchWrite(0x82, 16);
    try touchWrite(0x83, 60);
    try touchWrite(0x84, 10);
    try touchWrite(0x85, 20);
    try touchWrite(0x87, 2);
    try touchWrite(0x88, 12);
    try touchWrite(0x89, 40);
    log.info("ft5x06 touch initialized", .{});
}

fn touchWrite(reg: u8, value: u8) !void {
    try board_i2c_bus.open();
    const i2c = try board_i2c_bus.device(ft5x06_address);
    try i2c.write(ft5x06_address, &.{ reg, value });
}

fn touchRead(reg: u8, data: []u8) !void {
    try board_i2c_bus.open();
    const i2c = try board_i2c_bus.device(ft5x06_address);
    try i2c.writeRead(ft5x06_address, &.{reg}, data);
}

fn readTouchForUi() ?player_ui.TouchPoint {
    const point = pollTouch() catch return null;
    const touch = point orelse return null;
    return .{ .x = touch.x, .y = touch.y };
}

fn boardI2cError(name: []const u8, err: anyerror) c_int {
    log.err("{s} failed: {s}", .{ name, @errorName(err) });
    return esp_fail;
}

const embed = @import("embed");
const esp = @import("esp");

const Es8311 = embed.drivers.audio.Es8311;
const log = esp.grt.std.log.scoped(.opus_player_board);

const i2c_port = 0;
const i2c_sda_gpio = 1;
const i2c_scl_gpio = 2;
const i2c_frequency_hz = 400_000;
const audio_sample_rate = 16_000;
const es8311_address = @intFromEnum(Es8311.Address.ad0_low);
const es8311_volume = 0xb0;
const esp_ok: c_int = 0;
const esp_fail: c_int = -1;

var board_i2c_bus = esp.embed.I2c.MasterBus.init(.{
    .port = i2c_port,
    .sda_io_num = i2c_sda_gpio,
    .scl_io_num = i2c_scl_gpio,
    .scl_speed_hz = i2c_frequency_hz,
});
var audio_codec: ?Es8311 = null;
var audio_ready = false;

pub const Track = enum(c_int) {
    twinkle = 0,
    happy_birthday = 1,
    doll_bear = 2,
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
extern fn szp_button_init() c_int;
extern fn szp_button_read_raw() bool;
extern fn szp_display_init() c_int;
extern fn szp_display_show_track(track: Track) c_int;

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
    try codec.setVolume(es8311_volume);
    try codec.setMute(false);

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

pub fn initButton() !void {
    try check("szp_button_init", szp_button_init());
}

pub fn buttonPressedRaw() bool {
    return szp_button_read_raw();
}

pub fn initDisplay() !void {
    try check("szp_display_init", szp_display_init());
}

pub fn showTrack(track: Track) !void {
    try check("szp_display_show_track", szp_display_show_track(track));
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

fn check(name: []const u8, rc: c_int) !void {
    if (rc == 0) return;
    log.err("{s} failed with rc={d}", .{ name, rc });
    return error.BoardCallFailed;
}

fn checkedI2cAddress(address: u8) !embed.drivers.I2c.Address {
    if (address > 0x7f) return error.InvalidI2cAddress;
    return @intCast(address);
}

fn boardI2cError(name: []const u8, err: anyerror) c_int {
    log.err("{s} failed: {s}", .{ name, @errorName(err) });
    return esp_fail;
}

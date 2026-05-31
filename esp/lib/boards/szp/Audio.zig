const embed = @import("embed_core");
const esp = @import("esp");

const Es7210 = embed.drivers.audio.Es7210;
const Es8311 = embed.drivers.audio.Es8311;

pub const Type = esp.embed.audio_adapter.Es8311Es7210System.make(.{
    .sample_rate = 16_000,
    .frame_samples_per_channel = 512,
    .mic_count = 2,
    .i2c = .{
        .port = 0,
        .sda_io_num = 1,
        .scl_io_num = 2,
        .scl_speed_hz = 100_000,
    },
    .i2s = .{
        .port = 1,
        .mclk_gpio = 38,
        .bclk_gpio = 14,
        .ws_gpio = 13,
        .dout_gpio = 45,
        .din_gpio = 12,
    },
    .es8311 = .{ .address = @intFromEnum(Es8311.Address.ad0_low) },
    .es7210 = .{
        .address = @intFromEnum(Es7210.Address.ad1_ad0_01),
        .mic_select = .{ .mic1 = true, .mic2 = true, .mic3 = true, .mic4 = true },
        .ref_channel = 2,
    },
    .capture = .{
        .raw_channel_count = 4,
        .ref_lane = 0,
        .mic_lanes = .{ 1, 3 },
    },
    .default_volume = 0xb0,
    .default_mic_gain_db = 24,
    .esp_sr = .{
        .monitor_gain = 3,
        .speech_enhancement = true,
    },
    .use_i2s_adapters = true,
    .i2s_adapters = .{
        .rx = .{
            .slots_per_frame = 4,
            .bytes_per_slot = @sizeOf(i16),
            .ref_channel = .{ .slot = 0 },
            .mic_channels = .{
                .{ .slot = 1 },
                .{ .slot = 3 },
            },
        },
        .tx = .{
            .slots_per_frame = 2,
            .bytes_per_slot = @sizeOf(i32),
            .speaker_slots = &.{
                .{ .index = 0, .sample_align = .msb },
                .{ .index = 1, .sample_align = .msb },
            },
        },
    },
});

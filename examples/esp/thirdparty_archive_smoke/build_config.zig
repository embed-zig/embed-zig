const esp_idf = @import("esp").idf;

pub const chip = "esp32s3";

pub const partition_table = esp_idf.PartitionTable.make(.{
    .entries = &.{
        .{
            .name = "nvs",
            .kind = .data,
            .subtype = .nvs,
            .size = 0x6000,
        },
        .{
            .name = "phy_init",
            .kind = .data,
            .subtype = .phy,
            .size = 0x1000,
        },
        .{
            .name = "factory",
            .kind = .app,
            .subtype = .factory,
            .size = 0x200000,
        },
    },
});

pub const sdk_config = esp_idf.SdkConfig.make(.{
    .ESPTOOLPY_FLASHSIZE = "16MB",
    .ESPTOOLPY_FLASHSIZE_16MB = true,
    .ESPTOOLPY_FLASHSIZE_2MB = false,
});

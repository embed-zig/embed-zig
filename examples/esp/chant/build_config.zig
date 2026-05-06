const esp_idf = @import("esp").idf;

pub const chip = "esp32s3";

pub const partition_table = esp_idf.PartitionTable.make(.{
    .entries = &.{
        .{
            .name = "nvs",
            .kind = .data,
            .subtype = .nvs,
            .size = 0x6000,
            .data = esp_idf.PartitionTable.data.nvs(.{}),
        },
        .{
            .name = "phy_init",
            .kind = .data,
            .subtype = .phy,
            .size = 0x1000,
        },
        .{
            .name = "coredump",
            .kind = .data,
            .subtype = .{ .custom_name = "coredump" },
            .size = 0x10000,
        },
        .{
            .name = "storage",
            .kind = .data,
            .subtype = .spiffs,
            .size = 0x200000,
            .data = esp_idf.PartitionTable.data.spiffs("partitions/spiffs"),
        },
        .{
            .name = "factory",
            .kind = .app,
            .subtype = .factory,
            .size = 0x600000,
        },
    },
});

pub const sdk_config = esp_idf.SdkConfig.make(.{
    .ESPTOOLPY_FLASHSIZE = "16MB",
    .ESPTOOLPY_FLASHSIZE_16MB = true,
    .ESPTOOLPY_FLASHSIZE_2MB = false,
    .ESP_MAIN_TASK_STACK_SIZE = 24 * 1024,
    .ESP_SYSTEM_PANIC_PRINT_REBOOT = true,
    .ESP_SYSTEM_PANIC_SILENT_REBOOT = false,
    .ESP_COREDUMP_ENABLE_TO_FLASH = true,
    .ESP_COREDUMP_ENABLE_TO_NONE = false,
    .ESP_COREDUMP_MAX_TASKS_NUM = 16,
    .ESP_COREDUMP_STACK_SIZE = 2048,
    .SPIFFS_MAX_PARTITIONS = 3,
    .SPI_FLASH_SIZE_OVERRIDE = true,
    .SPIRAM = true,
    .SPIRAM_MODE_QUAD = false,
    .SPIRAM_MODE_OCT = true,
    .SPIRAM_SPEED_40M = false,
    .SPIRAM_SPEED_80M = true,
    .SPIRAM_USE_CAPS_ALLOC = true,
    .SPIRAM_USE_MALLOC = false,
});

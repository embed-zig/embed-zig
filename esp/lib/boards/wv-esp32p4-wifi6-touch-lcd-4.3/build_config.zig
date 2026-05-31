const esp_idf = @import("esp").idf;

pub const chip = "esp32p4";

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
            .size = 0x400000,
        },
        .{
            .name = "model",
            .kind = .data,
            .subtype = .spiffs,
            .size = 0x50c000,
        },
        .{
            .name = "slave_fw",
            .kind = .data,
            .subtype = .{ .custom_value = 0x40 },
            .size = 0x200000,
        },
    },
});

pub const sdk_config = esp_idf.SdkConfig.make(.{
    .ESP32P4_SELECTS_REV_LESS_V3 = true,
    .ESP32P4_REV_MIN_1 = true,
    .ESPTOOLPY_FLASHMODE_QIO = true,
    .ESPTOOLPY_FLASHSIZE = "16MB",
    .ESPTOOLPY_FLASHSIZE_16MB = true,
    .ESPTOOLPY_FLASHSIZE_2MB = false,
    .SPI_FLASH_SIZE_OVERRIDE = true,
    .SPIRAM = true,
    .SPIRAM_SPEED_200M = true,
    .SPIRAM_XIP_FROM_PSRAM = true,
    .CACHE_L2_CACHE_256KB = true,
    .CACHE_L2_CACHE_LINE_128B = true,
    .ESP_MAIN_TASK_STACK_SIZE = 24 * 1024,
    .FREERTOS_HZ = 1000,
    .FREERTOS_TIMER_TASK_STACK_DEPTH = 4096,
    .ESP_TASK_WDT_EN = false,
    .ESP_WIFI_ENABLED = true,
    .ESP_WIFI_REMOTE_ENABLED = true,
    .ESP_WIFI_REMOTE_LIBRARY_HOSTED = true,
    .ESP_HOSTED_SDIO_HOST_INTERFACE = true,
    .SLAVE_IDF_TARGET_ESP32C6 = true,
    .BT_ENABLED = true,
    .BT_CONTROLLER_DISABLED = true,
    .BT_CONTROLLER_ENABLED = false,
    .BT_CONTROLLER_ONLY = false,
    .BT_BLUEDROID_ENABLED = false,
    .BT_NIMBLE_ENABLED = true,
    .BT_NIMBLE_TRANSPORT_UART = false,
    .ESP_HOSTED_ENABLE_BT_NIMBLE = true,
    .ESP_HOSTED_NIMBLE_HCI_VHCI = true,
    .USE_AFE = true,
    .AFE_INTERFACE_V1 = true,
    .DSP_ANSI = true,
    .DSP_OPTIMIZED = false,
    .DSP_OPTIMIZATION = 0,
});

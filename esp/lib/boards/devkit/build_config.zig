const esp_idf = @import("esp").idf;

pub const chip = "esp32s3";

pub const partition_table = esp_idf.PartitionTable.default_table;

pub const task_policy = .{
    .zux = .{
        .priority = 5,
    },
    .audio = .{
        .priority = 10,
        .core_id = 1,
    },
    .kcp = .{
        .priority = 10,
        .core_id = 1,
    },
    .netperf = .{
        .priority = 8,
        .core_id = 1,
    },
    .wifi_led = .{
        .priority = 5,
    },
};

pub const sdk_config = esp_idf.SdkConfig.make(.{
    .ESPTOOLPY_FLASHSIZE = "16MB",
    .ESPTOOLPY_FLASHSIZE_16MB = true,
    .ESPTOOLPY_FLASHSIZE_2MB = false,
    .ESP_WIFI_ENABLED = true,
    .ESP_WIFI_NVS_ENABLED = true,
    .BT_ENABLED = true,
    .BT_CONTROLLER_ENABLED = true,
    .BT_CONTROLLER_ONLY = true,
    .BT_BLUEDROID_ENABLED = false,
    .BT_NIMBLE_ENABLED = false,
    .BTDM_CTRL_MODE_BLE_ONLY = true,
    .ESP_MAIN_TASK_STACK_SIZE = 24 * 1024,
    .SPIRAM = true,
    .SPIRAM_MODE_QUAD = false,
    .SPIRAM_MODE_OCT = true,
    .SPIRAM_SPEED_40M = false,
    .SPIRAM_SPEED_80M = true,
    .SPIRAM_USE_CAPS_ALLOC = true,
    .SPIRAM_USE_MALLOC = false,
});

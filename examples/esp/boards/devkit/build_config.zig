const esp_idf = @import("esp").idf;

pub const chip = "esp32s3";

pub const partition_table = esp_idf.PartitionTable.default_table;

pub const sdk_config = esp_idf.SdkConfig.make(.{
    .ESPTOOLPY_FLASHSIZE = "16MB",
    .ESPTOOLPY_FLASHSIZE_16MB = true,
    .ESPTOOLPY_FLASHSIZE_2MB = false,
    .ESP_MAIN_TASK_STACK_SIZE = 24 * 1024,
    .SPIRAM = true,
    .SPIRAM_MODE_QUAD = false,
    .SPIRAM_MODE_OCT = true,
    .SPIRAM_SPEED_40M = false,
    .SPIRAM_SPEED_80M = true,
    .SPIRAM_USE_CAPS_ALLOC = true,
    .SPIRAM_USE_MALLOC = false,
});

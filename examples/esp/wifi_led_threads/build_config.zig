const esp_idf = @import("esp_idf");

pub const chip = "esp32s3";

pub const partition_table = esp_idf.PartitionTable.default_table;

pub const sdk_config = esp_idf.SdkConfig.make(.{
    .ESPTOOLPY_FLASHSIZE = "16MB",
    .ESPTOOLPY_FLASHSIZE_16MB = true,
    .ESPTOOLPY_FLASHSIZE_2MB = false,
    .ESP_WIFI_ENABLED = true,
    .ESP_WIFI_NVS_ENABLED = true,
});

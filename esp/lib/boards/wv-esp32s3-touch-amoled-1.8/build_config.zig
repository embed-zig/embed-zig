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
            .name = "factory",
            .kind = .app,
            .subtype = .factory,
            .size = 0x300000,
        },
    },
});

pub const task_policy = .{
    .zux = .{
        .priority = 5,
    },
    .audio = .{
        .priority = 10,
        .core_id = 1,
    },
    .kcp = .{
        .priority = 6,
        .core_id = 1,
    },
    .netperf = .{
        .priority = 5,
        .core_id = 1,
    },
    .esp = .{
        .priority = 7,
        .core_id = 1,
    },
    .lvgl = .{
        .priority = 5,
        .core_id = 1,
    },
    .gizclaw = .{
        .priority = 5,
        .core_id = 1,
    },
    .giznet = .{
        .priority = 5,
        .core_id = 1,
    },
    .sync = .{
        .priority = 5,
        .core_id = 1,
    },
    .testing = .{
        .priority = 5,
    },
};

pub const sdk_config = esp_idf.SdkConfig.make(.{
    .ESPTOOLPY_FLASHSIZE = "4MB",
    .ESPTOOLPY_FLASHSIZE_4MB = true,
    .ESPTOOLPY_FLASHSIZE_2MB = false,
    .ESP_MAIN_TASK_STACK_SIZE = 64 * 1024,
    .ESP_SYSTEM_PANIC_PRINT_REBOOT = true,
    .ESP_SYSTEM_PANIC_SILENT_REBOOT = false,
    .ESP_DEFAULT_CPU_FREQ_MHZ_160 = false,
    .ESP_DEFAULT_CPU_FREQ_MHZ_240 = true,
    .ESP_DEFAULT_CPU_FREQ_MHZ = 240,
    .FREERTOS_HZ = 1000,
    .FREERTOS_USE_TRACE_FACILITY = true,
    .FREERTOS_GENERATE_RUN_TIME_STATS = true,
    .FREERTOS_RUN_TIME_COUNTER_TYPE_U32 = false,
    .FREERTOS_RUN_TIME_COUNTER_TYPE_U64 = true,
    .FREERTOS_RUN_TIME_STATS_USING_ESP_TIMER = true,
    .FREERTOS_RUN_TIME_STATS_USING_CPU_CLK = false,
    .ESP_COREDUMP_ENABLE_TO_FLASH = true,
    .ESP_COREDUMP_ENABLE_TO_NONE = false,
    .ESP_COREDUMP_MAX_TASKS_NUM = 16,
    .ESP_COREDUMP_STACK_SIZE = 2048,
    .SPI_FLASH_SIZE_OVERRIDE = false,
    .ESP_WIFI_ENABLED = true,
    .ESP_WIFI_NVS_ENABLED = true,
    .BT_ENABLED = true,
    .BT_CONTROLLER_ENABLED = true,
    .BT_CONTROLLER_ONLY = true,
    .BT_BLUEDROID_ENABLED = false,
    .BT_NIMBLE_ENABLED = false,
    .BTDM_CTRL_MODE_BLE_ONLY = true,
    .SPIRAM = true,
    .SPIRAM_MODE_QUAD = false,
    .SPIRAM_MODE_OCT = true,
    .SPIRAM_SPEED_40M = false,
    .SPIRAM_SPEED_80M = true,
    .SPIRAM_USE_CAPS_ALLOC = true,
    .SPIRAM_USE_MALLOC = false,
    .SPIRAM_TRY_ALLOCATE_WIFI_LWIP = true,
    .ESP_WIFI_STATIC_RX_BUFFER_NUM = 16,
    .ESP_WIFI_DYNAMIC_RX_BUFFER_NUM = 64,
    .ESP_WIFI_STATIC_TX_BUFFER = true,
    .ESP_WIFI_DYNAMIC_TX_BUFFER = false,
    .ESP_WIFI_STATIC_TX_BUFFER_NUM = 64,
    .ESP_WIFI_CACHE_TX_BUFFER_NUM = 128,
    .ESP_WIFI_AMPDU_TX_ENABLED = true,
    .ESP_WIFI_TX_BA_WIN = 32,
    .ESP_WIFI_AMPDU_RX_ENABLED = true,
    .ESP_WIFI_RX_BA_WIN = 10,
    .LWIP_TCP_SND_BUF_DEFAULT = 32 * 1440,
    .LWIP_TCP_WND_DEFAULT = 32 * 1440,
    .LWIP_TCP_RECVMBOX_SIZE = 48,
    .LWIP_UDP_RECVMBOX_SIZE = 48,
});

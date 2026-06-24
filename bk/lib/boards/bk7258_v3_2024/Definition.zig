pub fn Board(comptime armino: type) type {
    return struct {
        pub const name = "bk7258_v3_2024";
        pub const chip = "bk7258";

        pub const flashdb_kv_offset = 0x780000;
        pub const flashdb_kv_size = armino.PartitionTable.kb(128);
        pub const littlefs_offset = 0x7a0000;
        pub const littlefs_size_bytes = 256 * 1024;
        pub const littlefs_size = armino.PartitionTable.kb(256);
        pub const littlefs_mount_path = "/littlefs";
        pub const littlefs_source_dir = "partitions/littlefs";

        pub const ap = struct {
            pub const config = armino.Config.make(.{
                .SYS_PRINT_DEV_UART = false,
                .SYS_PRINT_DEV_MAILBOX = true,
                .SYS_PRINT_DEV_NULL = false,
                .FWD_CMD_TO_CPUx = true,
                .DUMP_UART_PRINT_PORT = 0,
                .UART_PRINT_PORT = 1,
                .MAILBOX = true,
                .MAILBOX_V2_0 = true,
                .MAILBOX_IPC = true,
                .MAILBOX_IPC_API_TASK_STACK_SIZE = 2048,
                .SLAVE_HEART_BEAT = true,
                .APP_MAIN_TASK_STACK_SIZE = 16 * 1024,
                .MEDIA = true,
                .MEDIA_DISPLAY_SERVICE = true,
                .LCD = true,
                .LCD_QSPI = true,
                .LCD_ST7701SN = false,
                .LCD_H050IWV = true,
                .GPIO_DEFAULT_SET_SUPPORT = true,
                .USR_GPIO_CFG_EN = true,
                .LDO3V3_CTRL_GPIO = 13,
                .I2C = true,
                .SIM_I2C = true,
                .SIM_I2C_HW_BOARD_V3 = true,
                .TP = true,
                .TP_GT911 = true,
                .TP_GT1151 = true,
                .TP_FT6336 = false,
                .TP_HY4633 = false,
                .TP_CST816D = false,
                .TP_RST_GPIO_ID = 9,
                .TP_INT_GPIO_ID = 6,
                .SARADC = true,
                .SARADC_MB = true,
                .SARADC_TEST = false,
                .SDMADC = true,
                .AUDIO = true,
                .AUDIO_DAC = true,
                .AUDIO_PLAY = true,
                .AUDIO_RECORD = true,
                .LVGL = false,
                .USB = false,
                .LWIP = true,
                .LWIP_V2_1 = true,
                .BK_NETIF = true,
                .NETIF_LWIP = true,
                .WIFI_ENABLE = true,
                .WIFI_TX_RAW_ENABLE = true,
                .WIFI6_CODE_STACK = false,
                .WIFI4 = true,
                .WIFI6 = false,
                .WIFI_VNET_CONTROLLER = true,
                .NET_PARAM = true,
                .BK_HOSTAPD = true,
                .PHY_CLIENT = true,
                .PHY_MB = true,
                .BLUETOOTH_AP = true,
                .BLUETOOTH_HOST_ONLY = false,
                .BT = false,
                .BLE = false,
                .BTDM_5_2 = false,
                .BTDM_CONTROLLER_ONLY = false,
                .BLUETOOTH_SUPPORT_IPC = true,
            });
            pub const usr_gpio_cfg = @embedFile("usr_gpio_cfg.h");
        };

        pub const cp = struct {
            pub const config = armino.Config.make(.{
                .SYS_PRINT_DEV_UART = true,
                .SYS_PRINT_DEV_MAILBOX = false,
                .SYS_PRINT_DEV_NULL = false,
                .FWD_CMD_TO_CPUx = true,
                .DUMP_UART_PRINT_PORT = 0,
                .UART_PRINT_PORT = 0,
                .MAILBOX = true,
                .MAILBOX_V2_0 = true,
                .MAILBOX_IPC = true,
                .SLAVE_HEART_BEAT = true,
                .BLUETOOTH = true,
                .BT = false,
                .BLE = true,
                .BLE_5_X = false,
                .BLE_4_2 = false,
                .BTDM_5_2 = true,
                .BTDM_5_2_MINDTREE = false,
                .BLUETOOTH_MULTI_CONTROLLER = false,
                .BTDM_CONTROLLER_ONLY = true,
                .BLUETOOTH_RELEASE_CODESIZE = false,
                .BLUETOOTH_BLE_SLAVE_ONLY = false,
                .BLUETOOTH_BLE_SLAVE_OBSERVER = false,
                .BLUETOOTH_BLE_DISCOVER_AUTO = true,
                .BLUETOOTH_SUPPORT_LPO_ROSC = false,
                .BLUETOOTH_SUPPORT_IPC = true,
                .BLUETOOTH_SUPPORT_IRAM_CODE = false,
                .BLUETOOTH_SUPPORT_COEX_RF_MODE_SWITCH = false,
                .BLUETOOTH_SLEEP_PHY_SWITCH = false,
                .BLUETOOTH_RF_MODE_POLAR = false,
                .BLUETOOTH_RF_MODE_IQ_HIGH_PLL = true,
                .BLUETOOTH_RF_MODE_IQ_LOW_PLL = false,
                .SARADC = true,
                .SARADC_SERVER = true,
                .SARADC_NEED_FLUSH = false,
                .SARADC_PM_CB_SUPPORT = true,
                .SARADC_MB = true,
                .TOUCH = false,
                .TOUCH_TEST = false,
            });
        };

        pub const partition_table = armino.PartitionTable.make(.{
            .entries = &.{
                .{
                    .name = "primary_bootloader",
                    .size = armino.PartitionTable.rawSize("68k"),
                    .kind = .code,
                    .read = true,
                    .write = false,
                },
                .{
                    .name = "primary_cp_app",
                    .size = armino.PartitionTable.rawSize("1360k"),
                    .kind = .code,
                    .read = true,
                    .write = false,
                },
                .{
                    .name = "primary_ap_app",
                    .size = armino.PartitionTable.rawSize("1156k"),
                    .kind = .code,
                    .read = true,
                    .write = false,
                },
                .{
                    .name = "ota",
                    .size = armino.PartitionTable.rawSize("1428K"),
                    .kind = .data,
                    .read = true,
                    .write = true,
                },
                .{
                    .name = "usr_config",
                    .size = armino.PartitionTable.rawSize("60K"),
                    .kind = .data,
                    .read = true,
                    .write = true,
                },
                .{
                    .name = "flashdb_kv",
                    .offset = flashdb_kv_offset,
                    .size = flashdb_kv_size,
                    .kind = .data,
                    .read = true,
                    .write = true,
                    .data = armino.PartitionTable.data.flashdbKv(.{}),
                },
                .{
                    .name = "littlefs",
                    .offset = littlefs_offset,
                    .size = littlefs_size,
                    .kind = .data,
                    .read = true,
                    .write = true,
                    .data = armino.PartitionTable.data.littlefs(.{
                        .source_dir = littlefs_source_dir,
                        .mount_path = littlefs_mount_path,
                    }),
                },
                .{
                    .name = "easyflash",
                    .offset = 0x7fa000,
                    .size = armino.PartitionTable.rawSize("8K"),
                    .kind = .data,
                    .read = true,
                    .write = true,
                },
                .{
                    .name = "easyflash_ap",
                    .offset = 0x7fc000,
                    .size = armino.PartitionTable.rawSize("8K"),
                    .kind = .data,
                    .read = true,
                    .write = true,
                },
                .{
                    .name = "sys_rf",
                    .offset = 0x7fe000,
                    .size = armino.PartitionTable.rawSize("4k"),
                    .kind = .data,
                    .read = true,
                    .write = true,
                },
                .{
                    .name = "sys_net",
                    .offset = 0x7ff000,
                    .size = armino.PartitionTable.rawSize("4k"),
                    .kind = .data,
                    .read = true,
                    .write = true,
                },
            },
        });

        pub const ram_regions = armino.RamRegions.make(.{
            .psram_capacity_size = "16M",
            .regions = &.{
                .{
                    .name = "AP_SPINLOCK",
                    .kind = .SRAM,
                    .offset = 0x28000000,
                    .size = armino.RamRegions.rawSize("0x010000"),
                },
                .{
                    .name = "AP_RAM",
                    .kind = .SRAM,
                    .size = armino.RamRegions.rawSize("0x054000"),
                },
                .{
                    .name = "CP_RAM",
                    .kind = .SRAM,
                    .size = armino.RamRegions.rawSize("0x03b700"),
                },
                .{
                    .name = "PWR_MNG",
                    .kind = .SRAM,
                    .size = armino.RamRegions.rawSize("0x000100"),
                },
                .{
                    .name = "SWAP",
                    .kind = .SRAM,
                    .size = armino.RamRegions.rawSize("0x000800"),
                },
                .{
                    .name = "PSRAM_MEM_SLAB_USER",
                    .kind = .PSRAM,
                    .offset = 0x60000000,
                    .size = armino.RamRegions.rawSize("0x019000"),
                },
                .{
                    .name = "PSRAM_MEM_SLAB_AUDIO",
                    .kind = .PSRAM,
                    .size = armino.RamRegions.rawSize("0x019000"),
                },
                .{
                    .name = "PSRAM_MEM_SLAB_ENCODE",
                    .kind = .PSRAM,
                    .size = armino.RamRegions.rawSize("0x15E000"),
                },
                .{
                    .name = "PSRAM_MEM_SLAB_DISPLAY",
                    .kind = .PSRAM,
                    .size = armino.RamRegions.rawSize("0x570000"),
                },
                .{
                    .name = "CP_PSRAM_HEAP",
                    .kind = .PSRAM,
                    .size = armino.RamRegions.rawSize("0x020000"),
                },
                .{
                    .name = "AP_PSRAM_HEAP",
                    .kind = .PSRAM,
                    .size = armino.RamRegions.rawSize("0x8a0000"),
                },
                .{
                    .name = "AP_PSRAM_SECTION",
                    .kind = .PSRAM,
                    .size = armino.RamRegions.rawSize("0x040000"),
                },
            },
        });
    };
}

const Def = @import("../../lib/boards/bk7258_v3_2024/Definition.zig").Board(@import("../../lib/armino.zig"));

pub const name = Def.name;
pub const chip = Def.chip;

pub const flashdb_kv_offset = Def.flashdb_kv_offset;
pub const flashdb_kv_size = Def.flashdb_kv_size;
pub const littlefs_offset = Def.littlefs_offset;
pub const littlefs_size_bytes = Def.littlefs_size_bytes;
pub const littlefs_size = Def.littlefs_size;
pub const littlefs_mount_path = Def.littlefs_mount_path;
pub const littlefs_source_dir = Def.littlefs_source_dir;

pub const ap = Def.ap;
pub const cp = Def.cp;
pub const partition_table = Def.partition_table;
pub const ram_regions = Def.ram_regions;

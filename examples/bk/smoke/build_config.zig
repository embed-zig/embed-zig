const bk = @import("bk");

pub const Board = bk.boards.bk7258_v3_2024.Board;

pub const chip = Board.chip;

pub const flashdb_kv_offset = Board.flashdb_kv_offset;
pub const flashdb_kv_size = Board.flashdb_kv_size;
pub const littlefs_offset = Board.littlefs_offset;
pub const littlefs_size_bytes = Board.littlefs_size_bytes;
pub const littlefs_size = Board.littlefs_size;
pub const littlefs_mount_path = Board.littlefs_mount_path;
pub const littlefs_source_dir = Board.littlefs_source_dir;

pub const ap = Board.ap;
pub const cp = Board.cp;
pub const partition_table = Board.partition_table;
pub const ram_regions = Board.ram_regions;

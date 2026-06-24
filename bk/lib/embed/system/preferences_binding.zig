pub const ok: c_int = 0;
pub const invalid_arg: c_int = 1;
pub const invalid_state: c_int = 2;
pub const not_found: c_int = 3;
pub const no_mem: c_int = 4;
pub const no_space: c_int = 5;
pub const invalid_name: c_int = 6;
pub const unexpected: c_int = 9;

pub const Entry = extern struct {
    namespace_name: [16]u8,
    key: [16]u8,
    value_len: usize,
};

pub const Namespace = extern struct {
    name: [16]u8,
};

pub extern fn bk_embed_preferences_init() c_int;
pub extern fn bk_embed_preferences_get(
    namespace_ptr: [*]const u8,
    namespace_len: usize,
    key_ptr: [*]const u8,
    key_len: usize,
    out_ptr: ?[*]u8,
    inout_len: *usize,
) c_int;
pub extern fn bk_embed_preferences_put(
    namespace_ptr: [*]const u8,
    namespace_len: usize,
    key_ptr: [*]const u8,
    key_len: usize,
    value_ptr: [*]const u8,
    value_len: usize,
) c_int;
pub extern fn bk_embed_preferences_remove(
    namespace_ptr: [*]const u8,
    namespace_len: usize,
    key_ptr: [*]const u8,
    key_len: usize,
) c_int;
pub extern fn bk_embed_preferences_contains(
    namespace_ptr: [*]const u8,
    namespace_len: usize,
    key_ptr: [*]const u8,
    key_len: usize,
) bool;
pub extern fn bk_embed_preferences_list(
    namespace_ptr: [*]const u8,
    namespace_len: usize,
    out_entries: ?[*]Entry,
    capacity: usize,
    out_count: *usize,
) c_int;
pub extern fn bk_embed_preferences_list_namespaces(
    out_namespaces: ?[*]Namespace,
    capacity: usize,
    out_count: *usize,
) c_int;
pub extern fn bk_embed_preferences_clear(
    namespace_ptr: [*]const u8,
    namespace_len: usize,
) c_int;
pub extern fn bk_embed_preferences_sync() c_int;

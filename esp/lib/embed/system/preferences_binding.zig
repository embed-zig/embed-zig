pub const Handle = ?*anyopaque;

pub extern const esp_embed_preferences_ok: i32;
pub extern const esp_embed_preferences_err_invalid_arg: i32;
pub extern const esp_embed_preferences_err_invalid_state: i32;
pub extern const esp_embed_preferences_err_not_found: i32;
pub extern const esp_embed_preferences_err_no_mem: i32;
pub extern const esp_embed_preferences_err_no_free_pages: i32;
pub extern const esp_embed_preferences_err_new_version_found: i32;
pub extern const esp_embed_preferences_err_nvs_not_enough_space: i32;
pub extern const esp_embed_preferences_err_nvs_invalid_length: i32;
pub extern const esp_embed_preferences_err_nvs_value_too_long: i32;
pub extern const esp_embed_preferences_err_nvs_invalid_name: i32;
pub extern const esp_embed_preferences_err_nvs_invalid_handle: i32;
pub extern const esp_embed_preferences_err_nvs_read_only: i32;

pub extern fn esp_embed_preferences_init() i32;
pub extern fn esp_embed_preferences_open(
    namespace_ptr: [*]const u8,
    namespace_len: usize,
    read_only: bool,
    out_handle: *Handle,
) i32;
pub extern fn esp_embed_preferences_close(handle: Handle) void;
pub extern fn esp_embed_preferences_get(
    handle: Handle,
    key_ptr: [*]const u8,
    key_len: usize,
    out_ptr: [*]u8,
    inout_len: *usize,
) i32;
pub extern fn esp_embed_preferences_put(
    handle: Handle,
    key_ptr: [*]const u8,
    key_len: usize,
    value_ptr: [*]const u8,
    value_len: usize,
) i32;
pub extern fn esp_embed_preferences_remove(
    handle: Handle,
    key_ptr: [*]const u8,
    key_len: usize,
) i32;
pub extern fn esp_embed_preferences_contains(
    handle: Handle,
    key_ptr: [*]const u8,
    key_len: usize,
) bool;
pub extern fn esp_embed_preferences_clear(handle: Handle) i32;
pub extern fn esp_embed_preferences_sync(handle: Handle) i32;

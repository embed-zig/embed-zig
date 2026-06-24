#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "esp_err.h"
#include "nvs.h"
#include "nvs_flash.h"

const int esp_embed_preferences_ok = ESP_OK;
const int esp_embed_preferences_err_invalid_arg = ESP_ERR_INVALID_ARG;
const int esp_embed_preferences_err_invalid_state = ESP_ERR_INVALID_STATE;
const int esp_embed_preferences_err_not_found = ESP_ERR_NVS_NOT_FOUND;
const int esp_embed_preferences_err_no_mem = ESP_ERR_NO_MEM;
const int esp_embed_preferences_err_no_free_pages = ESP_ERR_NVS_NO_FREE_PAGES;
const int esp_embed_preferences_err_new_version_found = ESP_ERR_NVS_NEW_VERSION_FOUND;
const int esp_embed_preferences_err_nvs_not_enough_space = ESP_ERR_NVS_NOT_ENOUGH_SPACE;
const int esp_embed_preferences_err_nvs_invalid_length = ESP_ERR_NVS_INVALID_LENGTH;
const int esp_embed_preferences_err_nvs_value_too_long = ESP_ERR_NVS_VALUE_TOO_LONG;
const int esp_embed_preferences_err_nvs_invalid_name = ESP_ERR_NVS_INVALID_NAME;
const int esp_embed_preferences_err_nvs_invalid_handle = ESP_ERR_NVS_INVALID_HANDLE;
const int esp_embed_preferences_err_nvs_read_only = ESP_ERR_NVS_READ_ONLY;

typedef struct {
    char namespace_name[16];
    char key[16];
    int type;
    size_t value_len;
} esp_embed_preferences_entry_t;

typedef struct {
    char name[16];
} esp_embed_preferences_namespace_t;

static void copy_truncated_cstr(char *dst, size_t dst_len, const char *src)
{
    if (dst == NULL || dst_len == 0) {
        return;
    }
    size_t len = 0;
    if (src != NULL) {
        len = strnlen(src, dst_len - 1);
        memcpy(dst, src, len);
    }
    dst[len] = '\0';
}

static esp_err_t copy_nvs_name(char *dst, size_t dst_len, const uint8_t *src, size_t src_len)
{
    if ((src == NULL && src_len != 0) || dst == NULL || dst_len == 0) {
        return ESP_ERR_INVALID_ARG;
    }
    if (src_len == 0 || src_len >= dst_len) {
        return ESP_ERR_NVS_INVALID_NAME;
    }
    memcpy(dst, src, src_len);
    dst[src_len] = '\0';
    return ESP_OK;
}

int esp_embed_preferences_init(void)
{
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_INVALID_STATE) {
        return ESP_OK;
    }
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        err = nvs_flash_erase();
        if (err != ESP_OK) {
            return err;
        }
        err = nvs_flash_init();
    }
    return err;
}

int esp_embed_preferences_open(const uint8_t *namespace_ptr, size_t namespace_len, bool read_only, void **out_handle)
{
    if (out_handle == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    *out_handle = NULL;

    char namespace_name[16];
    esp_err_t err = copy_nvs_name(namespace_name, sizeof(namespace_name), namespace_ptr, namespace_len);
    if (err != ESP_OK) {
        return err;
    }

    nvs_handle_t handle = 0;
    err = nvs_open(namespace_name, read_only ? NVS_READONLY : NVS_READWRITE, &handle);
    if (err != ESP_OK) {
        return err;
    }
    *out_handle = (void *)(uintptr_t)handle;
    return ESP_OK;
}

void esp_embed_preferences_close(void *handle)
{
    if (handle == NULL) {
        return;
    }
    nvs_close((nvs_handle_t)(uintptr_t)handle);
}

int esp_embed_preferences_get(void *handle, const uint8_t *key_ptr, size_t key_len, uint8_t *out_ptr, size_t *inout_len)
{
    if (handle == NULL || inout_len == NULL || (out_ptr == NULL && *inout_len != 0)) {
        return ESP_ERR_INVALID_ARG;
    }

    char key[16];
    esp_err_t err = copy_nvs_name(key, sizeof(key), key_ptr, key_len);
    if (err != ESP_OK) {
        return err;
    }

    return nvs_get_blob((nvs_handle_t)(uintptr_t)handle, key, out_ptr, inout_len);
}

int esp_embed_preferences_put(void *handle, const uint8_t *key_ptr, size_t key_len, const uint8_t *value_ptr, size_t value_len)
{
    if (handle == NULL || (value_ptr == NULL && value_len != 0)) {
        return ESP_ERR_INVALID_ARG;
    }

    char key[16];
    esp_err_t err = copy_nvs_name(key, sizeof(key), key_ptr, key_len);
    if (err != ESP_OK) {
        return err;
    }

    err = nvs_set_blob((nvs_handle_t)(uintptr_t)handle, key, value_ptr, value_len);
    if (err != ESP_OK) {
        return err;
    }
    return nvs_commit((nvs_handle_t)(uintptr_t)handle);
}

int esp_embed_preferences_remove(void *handle, const uint8_t *key_ptr, size_t key_len)
{
    if (handle == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    char key[16];
    esp_err_t err = copy_nvs_name(key, sizeof(key), key_ptr, key_len);
    if (err != ESP_OK) {
        return err;
    }

    err = nvs_erase_key((nvs_handle_t)(uintptr_t)handle, key);
    if (err != ESP_OK) {
        return err;
    }
    return nvs_commit((nvs_handle_t)(uintptr_t)handle);
}

bool esp_embed_preferences_contains(void *handle, const uint8_t *key_ptr, size_t key_len)
{
    if (handle == NULL) {
        return false;
    }

    char key[16];
    if (copy_nvs_name(key, sizeof(key), key_ptr, key_len) != ESP_OK) {
        return false;
    }

    size_t required = 0;
    return nvs_get_blob((nvs_handle_t)(uintptr_t)handle, key, NULL, &required) == ESP_OK;
}

static size_t value_len_for_type(nvs_handle_t handle, const nvs_entry_info_t *info)
{
    switch (info->type) {
    case NVS_TYPE_U8:
    case NVS_TYPE_I8:
        return 1;
    case NVS_TYPE_U16:
    case NVS_TYPE_I16:
        return 2;
    case NVS_TYPE_U32:
    case NVS_TYPE_I32:
        return 4;
    case NVS_TYPE_U64:
    case NVS_TYPE_I64:
        return 8;
    case NVS_TYPE_STR: {
        size_t required = 0;
        if (nvs_get_str(handle, info->key, NULL, &required) == ESP_OK) {
            return required;
        }
        return 0;
    }
    case NVS_TYPE_BLOB: {
        size_t required = 0;
        if (nvs_get_blob(handle, info->key, NULL, &required) == ESP_OK) {
            return required;
        }
        return 0;
    }
    default:
        return 0;
    }
}

static size_t value_len_for_global_entry(const nvs_entry_info_t *info)
{
    nvs_handle_t handle = 0;
    esp_err_t err = nvs_open(info->namespace_name, NVS_READONLY, &handle);
    if (err != ESP_OK) {
        return 0;
    }
    size_t len = value_len_for_type(handle, info);
    nvs_close(handle);
    return len;
}

int esp_embed_preferences_list(void *handle, esp_embed_preferences_entry_t *out_entries, size_t capacity, size_t *out_count)
{
    if (handle == NULL || out_count == NULL || (out_entries == NULL && capacity != 0)) {
        return ESP_ERR_INVALID_ARG;
    }
    *out_count = 0;

    nvs_iterator_t iterator = NULL;
    esp_err_t err = nvs_entry_find_in_handle((nvs_handle_t)(uintptr_t)handle, NVS_TYPE_ANY, &iterator);
    if (err == ESP_ERR_NVS_NOT_FOUND) {
        return ESP_OK;
    }
    if (err != ESP_OK) {
        return err;
    }

    size_t count = 0;
    while (iterator != NULL) {
        nvs_entry_info_t info;
        nvs_entry_info(iterator, &info);

        if (count < capacity) {
            memset(&out_entries[count], 0, sizeof(out_entries[count]));
            copy_truncated_cstr(out_entries[count].namespace_name, sizeof(out_entries[count].namespace_name), info.namespace_name);
            copy_truncated_cstr(out_entries[count].key, sizeof(out_entries[count].key), info.key);
            out_entries[count].type = (int)info.type;
            out_entries[count].value_len = value_len_for_type((nvs_handle_t)(uintptr_t)handle, &info);
        }
        count++;

        err = nvs_entry_next(&iterator);
        if (err == ESP_ERR_NVS_NOT_FOUND) {
            break;
        }
        if (err != ESP_OK) {
            nvs_release_iterator(iterator);
            return err;
        }
    }

    nvs_release_iterator(iterator);
    *out_count = count;
    return ESP_OK;
}

static bool namespace_seen(const esp_embed_preferences_namespace_t *namespaces, size_t count, const char *name)
{
    for (size_t i = 0; i < count; i += 1) {
        if (strncmp(namespaces[i].name, name, sizeof(namespaces[i].name)) == 0) {
            return true;
        }
    }
    return false;
}

int esp_embed_preferences_list_namespaces(esp_embed_preferences_namespace_t *out_namespaces, size_t capacity, size_t *out_count)
{
    if (out_count == NULL || (out_namespaces == NULL && capacity != 0)) {
        return ESP_ERR_INVALID_ARG;
    }
    *out_count = 0;

    nvs_iterator_t iterator = NULL;
    esp_err_t err = nvs_entry_find(NVS_DEFAULT_PART_NAME, NULL, NVS_TYPE_ANY, &iterator);
    if (err == ESP_ERR_NVS_NOT_FOUND) {
        return ESP_OK;
    }
    if (err != ESP_OK) {
        return err;
    }

    esp_embed_preferences_namespace_t seen[32];
    size_t seen_count = 0;
    size_t count = 0;
    while (iterator != NULL) {
        nvs_entry_info_t info;
        nvs_entry_info(iterator, &info);

        if (!namespace_seen(seen, seen_count, info.namespace_name)) {
            if (seen_count < sizeof(seen) / sizeof(seen[0])) {
                memset(&seen[seen_count], 0, sizeof(seen[seen_count]));
                copy_truncated_cstr(seen[seen_count].name, sizeof(seen[seen_count].name), info.namespace_name);
                seen_count++;
            }
            if (count < capacity) {
                memset(&out_namespaces[count], 0, sizeof(out_namespaces[count]));
                copy_truncated_cstr(out_namespaces[count].name, sizeof(out_namespaces[count].name), info.namespace_name);
            }
            count++;
        }

        err = nvs_entry_next(&iterator);
        if (err == ESP_ERR_NVS_NOT_FOUND) {
            break;
        }
        if (err != ESP_OK) {
            nvs_release_iterator(iterator);
            return err;
        }
    }

    nvs_release_iterator(iterator);
    *out_count = count;
    return ESP_OK;
}

int esp_embed_preferences_clear(void *handle)
{
    if (handle == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    esp_err_t err = nvs_erase_all((nvs_handle_t)(uintptr_t)handle);
    if (err != ESP_OK) {
        return err;
    }
    return nvs_commit((nvs_handle_t)(uintptr_t)handle);
}

int esp_embed_preferences_sync(void *handle)
{
    if (handle == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    return nvs_commit((nvs_handle_t)(uintptr_t)handle);
}

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

/*
 * ARMINO's FlashDB fal_cfg.h checks the TSDB address macros when KVDB is
 * enabled even if TSDB itself is disabled. Keep the unused TSDB partition at
 * zero so the generated BK config only needs to describe the KVDB partition.
 */
#ifndef CONFIG_FLASHDB_TSDB_START_ADDR
#define CONFIG_FLASHDB_TSDB_START_ADDR 0
#endif
#ifndef CONFIG_FLASHDB_TSDB_SIZE
#define CONFIG_FLASHDB_TSDB_SIZE 0
#endif

#include "flashdb.h"
#include "driver/flash.h"
#include "os/os.h"

#define BK_EMBED_PREF_OK 0
#define BK_EMBED_PREF_INVALID_ARG 1
#define BK_EMBED_PREF_INVALID_STATE 2
#define BK_EMBED_PREF_NOT_FOUND 3
#define BK_EMBED_PREF_NO_MEM 4
#define BK_EMBED_PREF_NO_SPACE 5
#define BK_EMBED_PREF_INVALID_NAME 6
#define BK_EMBED_PREF_UNEXPECTED 9

#define BK_EMBED_PREF_NAME_CAP 16
#define BK_EMBED_PREF_FULL_KEY_CAP 64
#define BK_EMBED_PREF_FLASH_ERASE_MIN_SIZE (4 * 1024)

typedef struct {
    char namespace_name[BK_EMBED_PREF_NAME_CAP];
    char key[BK_EMBED_PREF_NAME_CAP];
    size_t value_len;
} bk_embed_preferences_entry_t;

typedef struct {
    char name[BK_EMBED_PREF_NAME_CAP];
} bk_embed_preferences_namespace_t;

static struct fdb_kvdb s_kvdb;
static beken_mutex_t s_kvdb_mutex;
static beken_mutex_t s_flash_mutex;
static bool s_initialized;

static int flash_init(void)
{
    if (s_flash_mutex == NULL) {
        if (rtos_init_mutex(&s_flash_mutex) != 0) {
            return -1;
        }
    }
    g_flashdb0.len = CONFIG_FLASHDB_KVDB_START_ADDR + CONFIG_FLASHDB_KVDB_SIZE;
    return 1;
}

static int flash_read(long offset, uint8_t *buf, size_t size)
{
    if (s_flash_mutex == NULL && flash_init() < 0) {
        return -1;
    }

    rtos_lock_mutex(&s_flash_mutex);
    const int ret = bk_flash_read_bytes((uint32_t)offset, buf, (uint32_t)size);
    rtos_unlock_mutex(&s_flash_mutex);
    return ret;
}

static int flash_write(long offset, const uint8_t *buf, size_t size)
{
    if (s_flash_mutex == NULL && flash_init() < 0) {
        return -1;
    }

    rtos_lock_mutex(&s_flash_mutex);
    const int ret = bk_flash_write_bytes((uint32_t)offset, buf, (uint32_t)size);
    rtos_unlock_mutex(&s_flash_mutex);
    return ret;
}

static int flash_erase(long offset, size_t size)
{
    if (s_flash_mutex == NULL && flash_init() < 0) {
        return -1;
    }

    flash_protect_type_t protect_type = bk_flash_get_protect_type();
    if (protect_type != FLASH_PROTECT_NONE) {
        bk_flash_set_protect_type(FLASH_PROTECT_NONE);
    }

    rtos_lock_mutex(&s_flash_mutex);
    const uint32_t start = ((uint32_t)offset) & 0x00FFF000;
    const uint32_t end = (((uint32_t)offset + (uint32_t)size + BK_EMBED_PREF_FLASH_ERASE_MIN_SIZE - 1) &
        0x00FFF000);
    for (uint32_t addr = start; addr < end; addr += BK_EMBED_PREF_FLASH_ERASE_MIN_SIZE) {
        if (bk_flash_erase_sector(addr) != BK_OK) {
            rtos_unlock_mutex(&s_flash_mutex);
            if (protect_type != FLASH_PROTECT_NONE) {
                bk_flash_set_protect_type(protect_type);
            }
            return -1;
        }
    }
    rtos_unlock_mutex(&s_flash_mutex);

    if (protect_type != FLASH_PROTECT_NONE) {
        bk_flash_set_protect_type(protect_type);
    }
    return (int)size;
}

struct fal_flash_dev g_flashdb0 = {
    .name = FLASHDB_DEV_NAME,
    .addr = 0,
    .len = 0,
    .blk_size = BK_EMBED_PREF_FLASH_ERASE_MIN_SIZE,
    .ops = { flash_init, flash_read, flash_write, flash_erase },
    .write_gran = 8,
};

static void lock(fdb_db_t db)
{
    rtos_lock_mutex((beken_mutex_t *)db->user_data);
}

static void unlock(fdb_db_t db)
{
    rtos_unlock_mutex((beken_mutex_t *)db->user_data);
}

static int map_fdb_err(fdb_err_t err)
{
    switch (err) {
    case FDB_NO_ERR:
        return BK_EMBED_PREF_OK;
    case FDB_KV_NAME_ERR:
        return BK_EMBED_PREF_INVALID_NAME;
    case FDB_SAVED_FULL:
        return BK_EMBED_PREF_NO_SPACE;
    case FDB_INIT_FAILED:
        return BK_EMBED_PREF_INVALID_STATE;
    default:
        return BK_EMBED_PREF_UNEXPECTED;
    }
}

static bool valid_name(const uint8_t *ptr, size_t len)
{
    if (ptr == NULL || len == 0 || len >= BK_EMBED_PREF_NAME_CAP) {
        return false;
    }
    for (size_t i = 0; i < len; i += 1) {
        if (ptr[i] == '\0' || ptr[i] == ':') {
            return false;
        }
    }
    return true;
}

static int make_full_key(
    char out[BK_EMBED_PREF_FULL_KEY_CAP],
    const uint8_t *namespace_ptr,
    size_t namespace_len,
    const uint8_t *key_ptr,
    size_t key_len)
{
    if (!valid_name(namespace_ptr, namespace_len) || !valid_name(key_ptr, key_len)) {
        return BK_EMBED_PREF_INVALID_NAME;
    }
    if (namespace_len + 1 + key_len >= BK_EMBED_PREF_FULL_KEY_CAP) {
        return BK_EMBED_PREF_INVALID_NAME;
    }

    memcpy(out, namespace_ptr, namespace_len);
    out[namespace_len] = ':';
    memcpy(out + namespace_len + 1, key_ptr, key_len);
    out[namespace_len + 1 + key_len] = '\0';
    return BK_EMBED_PREF_OK;
}

static bool split_full_key(const char *full_key, char namespace_name[BK_EMBED_PREF_NAME_CAP], char key[BK_EMBED_PREF_NAME_CAP])
{
    const char *sep = strchr(full_key, ':');
    if (sep == NULL) {
        return false;
    }

    size_t namespace_len = (size_t)(sep - full_key);
    size_t key_len = strnlen(sep + 1, BK_EMBED_PREF_NAME_CAP);
    if (namespace_len == 0 || namespace_len >= BK_EMBED_PREF_NAME_CAP ||
        key_len == 0 || key_len >= BK_EMBED_PREF_NAME_CAP) {
        return false;
    }

    memset(namespace_name, 0, BK_EMBED_PREF_NAME_CAP);
    memset(key, 0, BK_EMBED_PREF_NAME_CAP);
    memcpy(namespace_name, full_key, namespace_len);
    memcpy(key, sep + 1, key_len);
    return true;
}

static bool namespace_matches(const char *full_key, const char *namespace_name)
{
    const size_t namespace_len = strnlen(namespace_name, BK_EMBED_PREF_NAME_CAP);
    return strncmp(full_key, namespace_name, namespace_len) == 0 && full_key[namespace_len] == ':';
}

static bool namespace_seen(const bk_embed_preferences_namespace_t *namespaces, size_t count, const char *name)
{
    for (size_t i = 0; i < count; i += 1) {
        if (strncmp(namespaces[i].name, name, BK_EMBED_PREF_NAME_CAP) == 0) {
            return true;
        }
    }
    return false;
}

int bk_embed_preferences_init(void)
{
    if (s_initialized) {
        return BK_EMBED_PREF_OK;
    }

    if (rtos_init_mutex(&s_kvdb_mutex) != 0) {
        return BK_EMBED_PREF_INVALID_STATE;
    }

    fdb_kvdb_control(&s_kvdb, FDB_KVDB_CTRL_SET_LOCK, (void *)lock);
    fdb_kvdb_control(&s_kvdb, FDB_KVDB_CTRL_SET_UNLOCK, (void *)unlock);
    const fdb_err_t err = fdb_kvdb_init(&s_kvdb, "embed_pref", "fdb_kvdb1", NULL, &s_kvdb_mutex);
    if (err != FDB_NO_ERR) {
        return map_fdb_err(err);
    }

    s_initialized = true;
    return BK_EMBED_PREF_OK;
}

int bk_embed_preferences_get(
    const uint8_t *namespace_ptr,
    size_t namespace_len,
    const uint8_t *key_ptr,
    size_t key_len,
    uint8_t *out_ptr,
    size_t *inout_len)
{
    if (inout_len == NULL || (out_ptr == NULL && *inout_len != 0)) {
        return BK_EMBED_PREF_INVALID_ARG;
    }
    int rc = bk_embed_preferences_init();
    if (rc != BK_EMBED_PREF_OK) {
        return rc;
    }

    char full_key[BK_EMBED_PREF_FULL_KEY_CAP];
    rc = make_full_key(full_key, namespace_ptr, namespace_len, key_ptr, key_len);
    if (rc != BK_EMBED_PREF_OK) {
        return rc;
    }

    struct fdb_kv kv;
    if (fdb_kv_get_obj(&s_kvdb, full_key, &kv) == NULL) {
        return BK_EMBED_PREF_NOT_FOUND;
    }

    const size_t required = kv.value_len;
    if (out_ptr == NULL || *inout_len < required) {
        *inout_len = required;
        return out_ptr == NULL ? BK_EMBED_PREF_OK : BK_EMBED_PREF_NO_SPACE;
    }

    struct fdb_blob blob;
    const size_t read_len = fdb_kv_get_blob(&s_kvdb, full_key, fdb_blob_make(&blob, out_ptr, *inout_len));
    *inout_len = required;
    return read_len == required ? BK_EMBED_PREF_OK : BK_EMBED_PREF_UNEXPECTED;
}

int bk_embed_preferences_put(
    const uint8_t *namespace_ptr,
    size_t namespace_len,
    const uint8_t *key_ptr,
    size_t key_len,
    const uint8_t *value_ptr,
    size_t value_len)
{
    if (value_ptr == NULL && value_len != 0) {
        return BK_EMBED_PREF_INVALID_ARG;
    }
    int rc = bk_embed_preferences_init();
    if (rc != BK_EMBED_PREF_OK) {
        return rc;
    }

    char full_key[BK_EMBED_PREF_FULL_KEY_CAP];
    rc = make_full_key(full_key, namespace_ptr, namespace_len, key_ptr, key_len);
    if (rc != BK_EMBED_PREF_OK) {
        return rc;
    }

    struct fdb_blob blob;
    return map_fdb_err(fdb_kv_set_blob(&s_kvdb, full_key, fdb_blob_make(&blob, value_ptr, value_len)));
}

int bk_embed_preferences_remove(
    const uint8_t *namespace_ptr,
    size_t namespace_len,
    const uint8_t *key_ptr,
    size_t key_len)
{
    int rc = bk_embed_preferences_init();
    if (rc != BK_EMBED_PREF_OK) {
        return rc;
    }

    char full_key[BK_EMBED_PREF_FULL_KEY_CAP];
    rc = make_full_key(full_key, namespace_ptr, namespace_len, key_ptr, key_len);
    if (rc != BK_EMBED_PREF_OK) {
        return rc;
    }

    struct fdb_kv kv;
    if (fdb_kv_get_obj(&s_kvdb, full_key, &kv) == NULL) {
        return BK_EMBED_PREF_NOT_FOUND;
    }
    return map_fdb_err(fdb_kv_del(&s_kvdb, full_key));
}

bool bk_embed_preferences_contains(
    const uint8_t *namespace_ptr,
    size_t namespace_len,
    const uint8_t *key_ptr,
    size_t key_len)
{
    if (bk_embed_preferences_init() != BK_EMBED_PREF_OK) {
        return false;
    }

    char full_key[BK_EMBED_PREF_FULL_KEY_CAP];
    if (make_full_key(full_key, namespace_ptr, namespace_len, key_ptr, key_len) != BK_EMBED_PREF_OK) {
        return false;
    }

    struct fdb_kv kv;
    return fdb_kv_get_obj(&s_kvdb, full_key, &kv) != NULL;
}

int bk_embed_preferences_list(
    const uint8_t *namespace_ptr,
    size_t namespace_len,
    bk_embed_preferences_entry_t *out_entries,
    size_t capacity,
    size_t *out_count)
{
    if (out_count == NULL || (out_entries == NULL && capacity != 0) ||
        !valid_name(namespace_ptr, namespace_len)) {
        return BK_EMBED_PREF_INVALID_ARG;
    }
    int rc = bk_embed_preferences_init();
    if (rc != BK_EMBED_PREF_OK) {
        return rc;
    }

    char namespace_name[BK_EMBED_PREF_NAME_CAP] = {0};
    memcpy(namespace_name, namespace_ptr, namespace_len);

    size_t count = 0;
    struct fdb_kv_iterator iterator;
    fdb_kv_iterator_init(&iterator);
    while (fdb_kv_iterate(&s_kvdb, &iterator)) {
        char iter_namespace[BK_EMBED_PREF_NAME_CAP];
        char iter_key[BK_EMBED_PREF_NAME_CAP];
        if (!split_full_key(iterator.curr_kv.name, iter_namespace, iter_key)) {
            continue;
        }
        if (strncmp(iter_namespace, namespace_name, BK_EMBED_PREF_NAME_CAP) != 0) {
            continue;
        }

        if (count < capacity) {
            memset(&out_entries[count], 0, sizeof(out_entries[count]));
            memcpy(out_entries[count].namespace_name, iter_namespace, BK_EMBED_PREF_NAME_CAP);
            memcpy(out_entries[count].key, iter_key, BK_EMBED_PREF_NAME_CAP);
            out_entries[count].value_len = iterator.curr_kv.value_len;
        }
        count += 1;
    }

    *out_count = count;
    return BK_EMBED_PREF_OK;
}

int bk_embed_preferences_list_namespaces(
    bk_embed_preferences_namespace_t *out_namespaces,
    size_t capacity,
    size_t *out_count)
{
    if (out_count == NULL || (out_namespaces == NULL && capacity != 0)) {
        return BK_EMBED_PREF_INVALID_ARG;
    }
    int rc = bk_embed_preferences_init();
    if (rc != BK_EMBED_PREF_OK) {
        return rc;
    }

    bk_embed_preferences_namespace_t seen[32];
    size_t seen_count = 0;
    size_t count = 0;
    struct fdb_kv_iterator iterator;
    fdb_kv_iterator_init(&iterator);
    while (fdb_kv_iterate(&s_kvdb, &iterator)) {
        char namespace_name[BK_EMBED_PREF_NAME_CAP];
        char key[BK_EMBED_PREF_NAME_CAP];
        if (!split_full_key(iterator.curr_kv.name, namespace_name, key)) {
            continue;
        }
        if (namespace_seen(seen, seen_count, namespace_name)) {
            continue;
        }

        if (seen_count < sizeof(seen) / sizeof(seen[0])) {
            memset(&seen[seen_count], 0, sizeof(seen[seen_count]));
            memcpy(seen[seen_count].name, namespace_name, BK_EMBED_PREF_NAME_CAP);
            seen_count += 1;
        }
        if (count < capacity) {
            memset(&out_namespaces[count], 0, sizeof(out_namespaces[count]));
            memcpy(out_namespaces[count].name, namespace_name, BK_EMBED_PREF_NAME_CAP);
        }
        count += 1;
    }

    *out_count = count;
    return BK_EMBED_PREF_OK;
}

int bk_embed_preferences_clear(const uint8_t *namespace_ptr, size_t namespace_len)
{
    if (!valid_name(namespace_ptr, namespace_len)) {
        return BK_EMBED_PREF_INVALID_ARG;
    }
    int rc = bk_embed_preferences_init();
    if (rc != BK_EMBED_PREF_OK) {
        return rc;
    }

    char namespace_name[BK_EMBED_PREF_NAME_CAP] = {0};
    memcpy(namespace_name, namespace_ptr, namespace_len);

    bool deleted = true;
    while (deleted) {
        deleted = false;
        struct fdb_kv_iterator iterator;
        fdb_kv_iterator_init(&iterator);
        while (fdb_kv_iterate(&s_kvdb, &iterator)) {
            if (!namespace_matches(iterator.curr_kv.name, namespace_name)) {
                continue;
            }
            rc = map_fdb_err(fdb_kv_del(&s_kvdb, iterator.curr_kv.name));
            if (rc != BK_EMBED_PREF_OK) {
                return rc;
            }
            deleted = true;
            break;
        }
    }

    return BK_EMBED_PREF_OK;
}

int bk_embed_preferences_sync(void)
{
    return bk_embed_preferences_init();
}

#include <stddef.h>

#include "esp_check.h"
#include "esp_spiffs.h"
#include "nvs_flash.h"

#define STORAGE_PARTITION_LABEL "storage"

static const char *TAG = "szp_storage";

int szp_storage_init_nvs(void)
{
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_RETURN_ON_ERROR(nvs_flash_erase(), TAG, "erase nvs");
        err = nvs_flash_init();
    }
    return err;
}

int szp_storage_mount(void)
{
    esp_vfs_spiffs_conf_t conf = {
        .base_path = "/spiffs",
        .partition_label = STORAGE_PARTITION_LABEL,
        .max_files = 5,
        .format_if_mount_failed = false,
    };
    return esp_vfs_spiffs_register(&conf);
}

int szp_storage_info(size_t *total, size_t *used)
{
    return esp_spiffs_info(STORAGE_PARTITION_LABEL, total, used);
}

int szp_storage_unmount(void)
{
    return esp_vfs_spiffs_unregister(STORAGE_PARTITION_LABEL);
}

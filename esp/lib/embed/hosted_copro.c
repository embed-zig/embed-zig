#include "esp_app_desc.h"
#include "esp_app_format.h"
#include "esp_check.h"
#include "esp_err.h"
#include "esp_event.h"
#include "esp_hosted.h"
#include "esp_hosted_api_types.h"
#include "esp_hosted_ota.h"
#include "esp_log.h"
#include "esp_partition.h"
#include "esp_system.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "nvs_flash.h"
#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#define ESP_EMBED_HOSTED_COPRO_CHUNK_SIZE 1500

static const char *TAG = "esp_hosted_copro";
static bool s_ready;

static esp_err_t ok_if_already_initialized(esp_err_t err) {
    if (err == ESP_ERR_INVALID_STATE) return ESP_OK;
    return err;
}

static esp_err_t init_nvs(void) {
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_RETURN_ON_ERROR(nvs_flash_erase(), TAG, "nvs erase");
        err = nvs_flash_init();
    }
    return err;
}

static bool version_matches(
    const esp_hosted_coprocessor_fwver_t *version,
    uint32_t expected_major,
    uint32_t expected_minor,
    uint32_t expected_patch
) {
    return version->major1 == expected_major &&
        version->minor1 == expected_minor &&
        version->patch1 == expected_patch;
}

static esp_err_t connect_slave(void) {
    ESP_RETURN_ON_ERROR(init_nvs(), TAG, "nvs init");
    ESP_RETURN_ON_ERROR(ok_if_already_initialized(esp_event_loop_create_default()), TAG, "event loop init");
    esp_err_t err = esp_hosted_init();
    if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) return err;
    err = esp_hosted_connect_to_slave();
    if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) return err;
    return ESP_OK;
}

static esp_err_t read_firmware_size(const esp_partition_t *partition, size_t *firmware_size) {
    esp_image_header_t image_header;
    esp_image_segment_header_t segment_header;
    esp_app_desc_t app_desc;
    size_t offset = 0;
    size_t total_size = 0;

    ESP_RETURN_ON_ERROR(esp_partition_read(partition, offset, &image_header, sizeof(image_header)), TAG, "read image header");
    ESP_RETURN_ON_FALSE(image_header.magic == ESP_IMAGE_HEADER_MAGIC, ESP_ERR_INVALID_ARG, TAG, "invalid image magic");

    offset = sizeof(image_header);
    total_size = sizeof(image_header);
    for (uint8_t i = 0; i < image_header.segment_count; i++) {
        ESP_RETURN_ON_ERROR(esp_partition_read(partition, offset, &segment_header, sizeof(segment_header)), TAG, "read segment header");
        total_size += sizeof(segment_header) + segment_header.data_len;

        if (i == 0) {
            size_t app_desc_offset = sizeof(image_header) + sizeof(segment_header);
            if (esp_partition_read(partition, app_desc_offset, &app_desc, sizeof(app_desc)) == ESP_OK) {
                ESP_LOGI(TAG, "slave_fw image project=%s version=%s", app_desc.project_name, app_desc.version);
            }
        }

        offset += sizeof(segment_header) + segment_header.data_len;
        ESP_RETURN_ON_FALSE(total_size <= partition->size, ESP_ERR_INVALID_SIZE, TAG, "image exceeds partition");
    }

    total_size += (16 - (total_size % 16)) % 16;
    total_size += 1;
    if (image_header.hash_appended == 1) {
        total_size += (16 - (total_size % 16)) % 16;
        total_size += 32;
    }

    ESP_RETURN_ON_FALSE(total_size <= partition->size, ESP_ERR_INVALID_SIZE, TAG, "image exceeds partition");
    *firmware_size = total_size;
    return ESP_OK;
}

static esp_err_t perform_partition_ota(const char *partition_label) {
    const esp_partition_t *partition = esp_partition_find_first(
        ESP_PARTITION_TYPE_DATA,
        ESP_PARTITION_SUBTYPE_ANY,
        partition_label
    );
    ESP_RETURN_ON_FALSE(partition != NULL, ESP_ERR_NOT_FOUND, TAG, "slave firmware partition not found");

    size_t firmware_size = 0;
    ESP_RETURN_ON_ERROR(read_firmware_size(partition, &firmware_size), TAG, "read slave firmware size");
    ESP_LOGW(TAG, "updating hosted copro from partition=%s size=%u", partition_label, (unsigned)firmware_size);

    ESP_RETURN_ON_ERROR(esp_hosted_slave_ota_begin(), TAG, "slave ota begin");

    uint8_t chunk[ESP_EMBED_HOSTED_COPRO_CHUNK_SIZE];
    size_t offset = 0;
    while (offset < firmware_size) {
        size_t chunk_len = firmware_size - offset;
        if (chunk_len > sizeof(chunk)) chunk_len = sizeof(chunk);
        esp_err_t err = esp_partition_read(partition, offset, chunk, chunk_len);
        if (err != ESP_OK) {
            esp_hosted_slave_ota_end();
            return err;
        }
        err = esp_hosted_slave_ota_write(chunk, (uint32_t)chunk_len);
        if (err != ESP_OK) {
            esp_hosted_slave_ota_end();
            return err;
        }
        offset += chunk_len;
    }

    ESP_RETURN_ON_ERROR(esp_hosted_slave_ota_end(), TAG, "slave ota end");
    ESP_LOGW(TAG, "hosted copro OTA completed, restarting host to resync slave");
    (void)esp_hosted_slave_ota_activate();
    vTaskDelay(pdMS_TO_TICKS(1000));
    esp_restart();
    return ESP_ERR_INVALID_STATE;
}

int esp_embed_hosted_copro_ensure_ready(
    const char *partition_label,
    uint32_t expected_major,
    uint32_t expected_minor,
    uint32_t expected_patch
) {
    if (s_ready) return ESP_OK;
    if (partition_label == NULL) return ESP_ERR_INVALID_ARG;

    esp_err_t err = connect_slave();
    if (err != ESP_OK) return err;

    esp_hosted_coprocessor_fwver_t version = {0};
    err = esp_hosted_get_coprocessor_fwversion(&version);
    if (err == ESP_OK) {
        ESP_LOGI(
            TAG,
            "hosted copro firmware version=%" PRIu32 ".%" PRIu32 ".%" PRIu32 " expected=%" PRIu32 ".%" PRIu32 ".%" PRIu32,
            version.major1,
            version.minor1,
            version.patch1,
            expected_major,
            expected_minor,
            expected_patch
        );
        if (version_matches(&version, expected_major, expected_minor, expected_patch)) {
            s_ready = true;
            return ESP_OK;
        }
    } else {
        ESP_LOGW(TAG, "could not read hosted copro firmware version rc=%d, trying partition OTA", (int)err);
    }

    return perform_partition_ota(partition_label);
}

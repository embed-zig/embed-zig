#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>

#include "esp_afe_sr_iface.h"
#include "esp_afe_sr_models.h"
#include "esp_check.h"
#include "esp_err.h"
#include "esp_log.h"

#define REQUIRED_MIC_CHANNELS 1
#define REQUIRED_REF_CHANNELS 1

typedef struct {
    uint32_t sample_rate_hz;
    size_t mic_count;
    size_t ref_count;
    int afe_task_priority;
    int speech_enhancement;
    int voice_communication_agc;
    int voice_communication_agc_gain;
} espz_esp_sr_afe_config_t;

static const char *TAG = "espz_esp_sr_afe";

static espz_esp_sr_afe_config_t config;
static bool configured;
static const esp_afe_sr_iface_t *afe_handle;
static esp_afe_sr_data_t *afe_data;
static int16_t *afe_feed_buffer;
static int16_t *mic_output_buffer;
static size_t afe_feed_fill_count;
static size_t afe_feed_since_fetch;
static size_t afe_output_pending_offset;
static size_t afe_output_pending_count;
static size_t mic_frame_count;
static size_t mic_output_sample_capacity;

static esp_err_t require_config(void)
{
    if (!configured) return ESP_ERR_INVALID_STATE;
    if (config.sample_rate_hz == 0) return ESP_ERR_INVALID_ARG;
    if (config.mic_count != REQUIRED_MIC_CHANNELS) return ESP_ERR_INVALID_ARG;
    if (config.ref_count != REQUIRED_REF_CHANNELS) return ESP_ERR_INVALID_ARG;
    return ESP_OK;
}

static void reset_buffers(void)
{
    if (afe_handle != NULL && afe_data != NULL) {
        afe_handle->reset_buffer(afe_data);
    }
    afe_feed_fill_count = 0;
    afe_feed_since_fetch = 0;
    afe_output_pending_offset = 0;
    afe_output_pending_count = 0;
}

static void deinit_afe_resources(void)
{
    if (afe_handle != NULL && afe_data != NULL) {
        afe_handle->destroy(afe_data);
    }
    afe_data = NULL;
    afe_handle = NULL;
    free(afe_feed_buffer);
    afe_feed_buffer = NULL;
    free(mic_output_buffer);
    mic_output_buffer = NULL;
    afe_feed_fill_count = 0;
    afe_feed_since_fetch = 0;
    afe_output_pending_offset = 0;
    afe_output_pending_count = 0;
    mic_frame_count = 0;
    mic_output_sample_capacity = 0;
}

static esp_err_t fail_afe_init(esp_err_t rc)
{
    deinit_afe_resources();
    return rc;
}

static size_t drain_pending_afe_output(int16_t *out, size_t out_capacity, size_t produced)
{
    if (produced >= out_capacity || afe_output_pending_count == 0) return produced;

    const size_t space = out_capacity - produced;
    const size_t n = afe_output_pending_count < space ? afe_output_pending_count : space;
    for (size_t i = 0; i < n; i += 1) {
        out[produced + i] = mic_output_buffer[afe_output_pending_offset + i];
    }
    afe_output_pending_offset += n;
    afe_output_pending_count -= n;
    if (afe_output_pending_count == 0) {
        afe_output_pending_offset = 0;
    }
    return produced + n;
}

int espz_esp_sr_afe_configure(const espz_esp_sr_afe_config_t *new_config)
{
    if (new_config == NULL) return ESP_ERR_INVALID_ARG;
    if (afe_data != NULL) return ESP_ERR_INVALID_STATE;
    config = *new_config;
    configured = true;
    return require_config();
}

int espz_esp_sr_afe_init(void)
{
    ESP_RETURN_ON_ERROR(require_config(), TAG, "config");
    if (afe_data != NULL) return ESP_OK;

    afe_config_t afe_config = AFE_CONFIG_DEFAULT();
    afe_config.aec_init = true;
    afe_config.se_init = config.speech_enhancement != 0;
    afe_config.vad_init = false;
    afe_config.wakenet_init = false;
    afe_config.voice_communication_init = true;
    afe_config.voice_communication_agc_init = config.voice_communication_agc != 0;
    afe_config.voice_communication_agc_gain = config.voice_communication_agc_gain;
    afe_config.afe_ns_mode = NS_MODE_SSP;
    afe_config.afe_ns_model_name = NULL;
    afe_config.memory_alloc_mode = AFE_MEMORY_ALLOC_MORE_PSRAM;
    afe_config.pcm_config.total_ch_num = (int)(config.mic_count + config.ref_count);
    afe_config.pcm_config.mic_num = (int)config.mic_count;
    afe_config.pcm_config.ref_num = (int)config.ref_count;
    afe_config.pcm_config.sample_rate = (int)config.sample_rate_hz;
    afe_config.afe_perferred_core = 1;
    afe_config.afe_perferred_priority = config.afe_task_priority;

    afe_handle = &ESP_AFE_VC_HANDLE;
    afe_data = afe_handle->create_from_config(&afe_config);
    if (afe_data == NULL) return ESP_FAIL;

    const int chunk_samples = afe_handle->get_feed_chunksize(afe_data);
    const int channel_count = afe_handle->get_total_channel_num(afe_data);
    if (chunk_samples <= 0 || channel_count <= 0) return fail_afe_init(ESP_FAIL);

    const size_t feed_sample_count = (size_t)chunk_samples * (size_t)channel_count;
    afe_feed_buffer = calloc(feed_sample_count, sizeof(int16_t));
    if (afe_feed_buffer == NULL) return fail_afe_init(ESP_ERR_NO_MEM);
    mic_frame_count = (size_t)chunk_samples;

    const int fetch_samples = afe_handle->get_fetch_chunksize(afe_data);
    if (fetch_samples <= 0) return fail_afe_init(ESP_FAIL);
    mic_output_sample_capacity = (size_t)fetch_samples;
    mic_output_buffer = calloc(mic_output_sample_capacity, sizeof(int16_t));
    if (mic_output_buffer == NULL) return fail_afe_init(ESP_ERR_NO_MEM);

    ESP_LOGI(
        TAG,
        "initialized: feed=%d samples channels=%d fetch=%d se=%d agc=%d",
        chunk_samples,
        channel_count,
        fetch_samples,
        config.speech_enhancement != 0,
        config.voice_communication_agc != 0);
    return ESP_OK;
}

void espz_esp_sr_afe_deinit(void)
{
    deinit_afe_resources();
    configured = false;
}

int espz_esp_sr_afe_reset(void)
{
    ESP_RETURN_ON_ERROR(espz_esp_sr_afe_init(), TAG, "init");
    reset_buffers();
    return ESP_OK;
}

int espz_esp_sr_afe_process_i16(
    const int16_t *mic,
    const int16_t *ref,
    size_t sample_count,
    int16_t *out,
    size_t out_capacity,
    size_t *out_count)
{
    if (out_count != NULL) *out_count = 0;
    if (mic == NULL || ref == NULL || out == NULL || out_count == NULL) return ESP_ERR_INVALID_ARG;
    ESP_RETURN_ON_ERROR(espz_esp_sr_afe_init(), TAG, "init");
    if (sample_count == 0) return ESP_OK;

    const size_t afe_channels = config.mic_count + config.ref_count;
    size_t produced = drain_pending_afe_output(out, out_capacity, 0);
    for (size_t i = 0; i < sample_count; i += 1) {
        const size_t feed_index = afe_feed_fill_count;
        afe_feed_buffer[feed_index * afe_channels] = mic[i];
        afe_feed_buffer[feed_index * afe_channels + config.mic_count] = ref[i];
        afe_feed_fill_count += 1;

        if (afe_feed_fill_count < mic_frame_count) continue;
        afe_feed_fill_count = 0;

        if (afe_handle->feed(afe_data, afe_feed_buffer) < 0) {
            return ESP_FAIL;
        }
        afe_feed_since_fetch += mic_frame_count;
        if (afe_feed_since_fetch < mic_output_sample_capacity) {
            continue;
        }
        if (produced >= out_capacity) {
            continue;
        }

        afe_fetch_result_t *result = afe_handle->fetch(afe_data);
        if (result == NULL || result->ret_value != ESP_OK || result->data == NULL || result->data_size <= 0) {
            continue;
        }
        afe_feed_since_fetch -= mic_output_sample_capacity;

        const size_t n = (size_t)result->data_size / sizeof(int16_t);
        if (n > mic_output_sample_capacity) return ESP_ERR_INVALID_SIZE;
        for (size_t j = 0; j < n; j += 1) {
            mic_output_buffer[j] = result->data[j];
        }
        afe_output_pending_offset = 0;
        afe_output_pending_count = n;
        produced = drain_pending_afe_output(out, out_capacity, produced);
    }
    *out_count = produced;
    return ESP_OK;
}

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "esp_aec.h"
#include "esp_check.h"
#include "esp_err.h"
#include "esp_heap_caps.h"
#include "esp_log.h"

#define REQUIRED_SAMPLE_RATE 16000
#define REQUIRED_MIC_CHANNELS 1
#define REQUIRED_REF_CHANNELS 1

typedef struct {
    uint32_t sample_rate_hz;
    size_t audio_frame_samples;
    size_t mic_count;
    size_t ref_count;
    int enable_aec;
    int aec_mode;
    int aec_filter_length;
    int aec_nlp_level;
    int aec_linear_only;
} espz_esp_sr_afe_config_t;

static const char *TAG = "espz_esp_sr_aec";

static espz_esp_sr_afe_config_t config;
static bool configured;
static aec_handle_t *aec_handle;
static int16_t *mic_frame_buffer;
static int16_t *ref_frame_buffer;
static int16_t *out_frame_buffer;
static size_t aec_process_frame_samples;
static bool direct_path_mismatch_logged;

static void *aec_frame_calloc(size_t count, size_t size)
{
    return heap_caps_aligned_calloc(16, count, size, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
}

static int aec_frame_ms(void)
{
    if (aec_process_frame_samples == 0) return 0;
    return (int)((aec_process_frame_samples * 1000) / config.sample_rate_hz);
}

static esp_err_t validate_config(const espz_esp_sr_afe_config_t *candidate)
{
    if (candidate == NULL) return ESP_ERR_INVALID_ARG;
    if (candidate->sample_rate_hz != REQUIRED_SAMPLE_RATE) return ESP_ERR_INVALID_ARG;
    if (candidate->mic_count != REQUIRED_MIC_CHANNELS) return ESP_ERR_INVALID_ARG;
    if (candidate->ref_count != REQUIRED_REF_CHANNELS) return ESP_ERR_INVALID_ARG;
    if (candidate->aec_filter_length <= 0) return ESP_ERR_INVALID_ARG;
    if (candidate->aec_mode != AEC_MODE_SR_LOW_COST &&
        candidate->aec_mode != AEC_MODE_SR_HIGH_PERF &&
        candidate->aec_mode != AEC_MODE_VOIP_LOW_COST &&
        candidate->aec_mode != AEC_MODE_VOIP_HIGH_PERF &&
        candidate->aec_mode != AEC_MODE_FD_LOW_COST &&
        candidate->aec_mode != AEC_MODE_FD_HIGH_PERF) {
        return ESP_ERR_INVALID_ARG;
    }
    if (candidate->aec_nlp_level != AEC_NLP_LEVEL_NORMAL &&
        candidate->aec_nlp_level != AEC_NLP_LEVEL_AGGR &&
        candidate->aec_nlp_level != AEC_NLP_LEVEL_VERYAGGR) {
        return ESP_ERR_INVALID_ARG;
    }
    return ESP_OK;
}

static esp_err_t require_config(void)
{
    if (!configured) return ESP_ERR_INVALID_STATE;
    return validate_config(&config);
}

static void reset_buffers(void)
{
    if (mic_frame_buffer != NULL) {
        memset(mic_frame_buffer, 0, aec_process_frame_samples * sizeof(int16_t));
    }
    if (ref_frame_buffer != NULL) {
        memset(ref_frame_buffer, 0, aec_process_frame_samples * sizeof(int16_t));
    }
    if (out_frame_buffer != NULL) {
        memset(out_frame_buffer, 0, aec_process_frame_samples * sizeof(int16_t));
    }
}

static void deinit_aec_resources(void)
{
    if (aec_handle != NULL) {
        aec_destroy(aec_handle);
        aec_handle = NULL;
    }
    heap_caps_free(mic_frame_buffer);
    mic_frame_buffer = NULL;
    heap_caps_free(ref_frame_buffer);
    ref_frame_buffer = NULL;
    heap_caps_free(out_frame_buffer);
    out_frame_buffer = NULL;
    aec_process_frame_samples = 0;
    direct_path_mismatch_logged = false;
}

static esp_err_t fail_aec_init(esp_err_t rc)
{
    deinit_aec_resources();
    return rc;
}

int espz_esp_sr_afe_configure(const espz_esp_sr_afe_config_t *new_config)
{
    if (aec_handle != NULL) return ESP_ERR_INVALID_STATE;
    ESP_RETURN_ON_ERROR(validate_config(new_config), TAG, "config");
    config = *new_config;
    configured = true;
    return ESP_OK;
}

int espz_esp_sr_afe_init(void)
{
    ESP_RETURN_ON_ERROR(require_config(), TAG, "config");
    if (aec_handle != NULL || config.enable_aec == 0) return ESP_OK;

    aec_config_t aec_config = {
        .mic_num = (int)config.mic_count,
        .ref_num = (int)config.ref_count,
        .out_num = 1,
        .filter_length = config.aec_filter_length,
        .sample_rate = (int)config.sample_rate_hz,
        .caps = MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT,
        .mode = (aec_mode_t)config.aec_mode,
        .nlp_level = (aec_nlp_level_t)config.aec_nlp_level,
    };

    aec_handle = aec_create_from_config(&aec_config);
    if (aec_handle == NULL) {
        ESP_LOGE(TAG, "aec_create_from_config failed mode=%d", config.aec_mode);
        return fail_aec_init(ESP_FAIL);
    }

    const int chunk_samples = aec_get_chunksize(aec_handle);
    if (chunk_samples <= 0) {
        ESP_LOGE(TAG, "aec_get_chunksize failed chunk=%d", chunk_samples);
        return fail_aec_init(ESP_FAIL);
    }
    aec_process_frame_samples = (size_t)chunk_samples;
    if (config.audio_frame_samples != aec_process_frame_samples) {
        ESP_LOGE(
            TAG,
            "audio frame samples mismatch audio_frame_samples=%u aec_frame_samples=%u sample_rate=%u",
            (unsigned)config.audio_frame_samples,
            (unsigned)aec_process_frame_samples,
            (unsigned)config.sample_rate_hz);
        return fail_aec_init(ESP_ERR_INVALID_SIZE);
    }

    mic_frame_buffer = (int16_t *)aec_frame_calloc(aec_process_frame_samples, sizeof(int16_t));
    if (mic_frame_buffer == NULL) {
        return fail_aec_init(ESP_ERR_NO_MEM);
    }
    ref_frame_buffer = (int16_t *)aec_frame_calloc(aec_process_frame_samples, sizeof(int16_t));
    if (ref_frame_buffer == NULL) {
        return fail_aec_init(ESP_ERR_NO_MEM);
    }
    out_frame_buffer = (int16_t *)aec_frame_calloc(aec_process_frame_samples, sizeof(int16_t));
    if (out_frame_buffer == NULL) {
        return fail_aec_init(ESP_ERR_NO_MEM);
    }

    const int frame_ms = aec_frame_ms();
    ESP_LOGI(
        TAG,
        "initialized aec frame_samples=%u audio_frame_samples=%u frame_ms=%d mode=%d mode_name=%s filter_length=%d nlp_level=%d linear_only=%d config=%s aec=%d scratch=aligned_8bit",
        (unsigned)aec_process_frame_samples,
        (unsigned)config.audio_frame_samples,
        frame_ms,
        config.aec_mode,
        aec_get_mode_string((aec_mode_t)config.aec_mode),
        config.aec_filter_length,
        config.aec_nlp_level,
        config.aec_linear_only != 0,
        aec_get_config_string(aec_handle),
        config.enable_aec != 0);
    return ESP_OK;
}

void espz_esp_sr_afe_deinit(void)
{
    deinit_aec_resources();
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

    if (config.enable_aec == 0) {
        const size_t n = sample_count < out_capacity ? sample_count : out_capacity;
        memcpy(out, mic, n * sizeof(int16_t));
        *out_count = n;
        return n == sample_count ? ESP_OK : ESP_ERR_INVALID_SIZE;
    }

    if (sample_count == aec_process_frame_samples &&
        out_capacity >= aec_process_frame_samples) {
        memcpy(mic_frame_buffer, mic, aec_process_frame_samples * sizeof(int16_t));
        memcpy(ref_frame_buffer, ref, aec_process_frame_samples * sizeof(int16_t));
        if (config.aec_linear_only != 0) {
            aec_linear_process(aec_handle, mic_frame_buffer, ref_frame_buffer, out_frame_buffer);
        } else {
            aec_process(aec_handle, mic_frame_buffer, ref_frame_buffer, out_frame_buffer);
        }
        memcpy(out, out_frame_buffer, aec_process_frame_samples * sizeof(int16_t));
        *out_count = aec_process_frame_samples;
        return ESP_OK;
    }

    if (!direct_path_mismatch_logged) {
        ESP_LOGE(
            TAG,
            "aec direct path unsupported sample_count=%u out_capacity=%u frame_samples=%u",
            (unsigned)sample_count,
            (unsigned)out_capacity,
            (unsigned)aec_process_frame_samples);
        direct_path_mismatch_logged = true;
    }
    return ESP_ERR_INVALID_SIZE;

}

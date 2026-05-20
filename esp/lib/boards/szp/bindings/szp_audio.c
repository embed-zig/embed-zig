#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>

#include "driver/i2s_std.h"
#include "esp_afe_sr_iface.h"
#include "esp_afe_sr_models.h"
#include "esp_check.h"
#include "esp_err.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"

#define SAMPLE_RATE_HZ 16000
#define I2S_MCLK_GPIO 38
#define I2S_BCLK_GPIO 14
#define I2S_WS_GPIO 13
#define I2S_DOUT_GPIO 45
#define I2S_DIN_GPIO 12
#define MONO_CHUNK_SAMPLES 256
#define MIC_AFE_TASK_PRIORITY 8
#define MIC_RX_CHANNELS 4
#define AFE_MIC_CHANNELS 2
#define AFE_REF_CHANNELS 1
#define AFE_CHANNELS (AFE_MIC_CHANNELS + AFE_REF_CHANNELS)
#define TX_REF_SATURATION_THRESHOLD 32000

static const char *TAG = "szp_audio";
static i2s_chan_handle_t tx_chan;
static i2s_chan_handle_t rx_chan;
static bool audio_ready;
static int32_t stereo_frame_32[MONO_CHUNK_SAMPLES * 2];
static const esp_afe_sr_iface_t *afe_handle;
static esp_afe_sr_data_t *afe_data;
static int16_t *afe_feed_buffer;
static int16_t *mic_output_buffer;
static int16_t mic_raw_capture_buffer[MONO_CHUNK_SAMPLES * MIC_RX_CHANNELS];
static size_t afe_feed_sample_count;
static size_t afe_feed_fill_count;
static size_t afe_feed_since_fetch;
static size_t afe_output_pending_offset;
static size_t afe_output_pending_count;
static size_t mic_frame_count;
static size_t mic_output_sample_capacity;
static SemaphoreHandle_t audio_write_mutex;
static volatile bool mic_capture_streaming;
static uint32_t raw_capture_log_count;

int szp_pca9557_set_pa(bool enabled);
int szp_audio_write_i16(const int16_t *pcm, size_t sample_count);

static void deinit_i2s_channels(void)
{
    if (tx_chan != NULL) {
        (void)i2s_channel_disable(tx_chan);
        (void)i2s_del_channel(tx_chan);
        tx_chan = NULL;
    }
    if (rx_chan != NULL) {
        (void)i2s_channel_disable(rx_chan);
        (void)i2s_del_channel(rx_chan);
        rx_chan = NULL;
    }
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
    afe_feed_sample_count = 0;
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

static esp_err_t init_i2s(void)
{
    if (tx_chan != NULL && rx_chan != NULL) return ESP_OK;
    if (audio_write_mutex == NULL) {
        audio_write_mutex = xSemaphoreCreateMutex();
        if (audio_write_mutex == NULL) return ESP_ERR_NO_MEM;
    }

    i2s_chan_config_t chan_cfg = I2S_CHANNEL_DEFAULT_CONFIG(I2S_NUM_1, I2S_ROLE_MASTER);
    chan_cfg.auto_clear = true;
    esp_err_t rc = i2s_new_channel(&chan_cfg, &tx_chan, &rx_chan);
    if (rc != ESP_OK) {
        deinit_i2s_channels();
        ESP_RETURN_ON_ERROR(rc, TAG, "new i2s channels");
    }

    i2s_std_config_t std_cfg = {
        .clk_cfg = I2S_STD_CLK_DEFAULT_CONFIG(SAMPLE_RATE_HZ),
        .slot_cfg = I2S_STD_PHILIPS_SLOT_DEFAULT_CONFIG(I2S_DATA_BIT_WIDTH_32BIT, I2S_SLOT_MODE_STEREO),
        .gpio_cfg = {
            .mclk = I2S_MCLK_GPIO,
            .bclk = I2S_BCLK_GPIO,
            .ws = I2S_WS_GPIO,
            .dout = I2S_DOUT_GPIO,
            .din = I2S_DIN_GPIO,
            .invert_flags = {
                .mclk_inv = false,
                .bclk_inv = false,
                .ws_inv = false,
            },
        },
    };
    rc = i2s_channel_init_std_mode(tx_chan, &std_cfg);
    if (rc != ESP_OK) {
        deinit_i2s_channels();
        ESP_RETURN_ON_ERROR(rc, TAG, "init i2s std");
    }
    rc = i2s_channel_init_std_mode(rx_chan, &std_cfg);
    if (rc != ESP_OK) {
        deinit_i2s_channels();
        ESP_RETURN_ON_ERROR(rc, TAG, "init i2s rx std");
    }
    rc = i2s_channel_enable(tx_chan);
    if (rc != ESP_OK) {
        deinit_i2s_channels();
        ESP_RETURN_ON_ERROR(rc, TAG, "enable i2s tx");
    }
    rc = i2s_channel_enable(rx_chan);
    if (rc != ESP_OK) {
        deinit_i2s_channels();
        ESP_RETURN_ON_ERROR(rc, TAG, "enable i2s rx");
    }
    return ESP_OK;
}

static esp_err_t init_afe(void)
{
    if (afe_data != NULL) return ESP_OK;

    afe_config_t config = AFE_CONFIG_DEFAULT();
    config.aec_init = true;
    config.se_init = false;
    config.vad_init = false;
    config.wakenet_init = false;
    config.voice_communication_init = true;
    config.voice_communication_agc_init = false;
    config.afe_ns_mode = NS_MODE_SSP;
    config.afe_ns_model_name = NULL;
    config.memory_alloc_mode = AFE_MEMORY_ALLOC_MORE_PSRAM;
    config.pcm_config.total_ch_num = AFE_CHANNELS;
    config.pcm_config.mic_num = AFE_MIC_CHANNELS;
    config.pcm_config.ref_num = AFE_REF_CHANNELS;
    config.pcm_config.sample_rate = SAMPLE_RATE_HZ;
    config.afe_perferred_core = 1;
    config.afe_perferred_priority = MIC_AFE_TASK_PRIORITY;

    afe_handle = &ESP_AFE_VC_HANDLE;
    afe_data = afe_handle->create_from_config(&config);
    if (afe_data == NULL) return ESP_FAIL;

    const int chunk_samples = afe_handle->get_feed_chunksize(afe_data);
    const int channel_count = afe_handle->get_total_channel_num(afe_data);
    if (chunk_samples <= 0 || channel_count <= 0) return fail_afe_init(ESP_FAIL);

    afe_feed_sample_count = (size_t)chunk_samples * (size_t)channel_count;
    afe_feed_buffer = calloc(afe_feed_sample_count, sizeof(int16_t));
    if (afe_feed_buffer == NULL) return fail_afe_init(ESP_ERR_NO_MEM);
    mic_frame_count = (size_t)chunk_samples;

    const int fetch_samples = afe_handle->get_fetch_chunksize(afe_data);
    if (fetch_samples <= 0) return fail_afe_init(ESP_FAIL);
    mic_output_sample_capacity = (size_t)fetch_samples;
    mic_output_buffer = calloc(mic_output_sample_capacity, sizeof(int16_t));
    if (mic_output_buffer == NULL) return fail_afe_init(ESP_ERR_NO_MEM);

    ESP_LOGI(TAG, "AFE initialized: feed=%d samples channels=%d fetch=%d", chunk_samples, channel_count, fetch_samples);
    return ESP_OK;
}

static int16_t peak_abs_i16(int16_t peak, int16_t sample)
{
    const int16_t value = sample == INT16_MIN ? INT16_MAX : (sample < 0 ? -sample : sample);
    return value > peak ? value : peak;
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

int szp_audio_init(void)
{
    if (audio_ready) return ESP_OK;

    ESP_RETURN_ON_ERROR(init_i2s(), TAG, "i2s init");
    audio_ready = true;
    return ESP_OK;
}

int szp_audio_set_pa(bool enabled)
{
    return szp_pca9557_set_pa(enabled);
}

int szp_audio_write_i16(const int16_t *pcm, size_t sample_count)
{
    if (!audio_ready || pcm == NULL) return ESP_ERR_INVALID_STATE;
    if (audio_write_mutex != NULL && xSemaphoreTake(audio_write_mutex, portMAX_DELAY) != pdTRUE) {
        return ESP_ERR_TIMEOUT;
    }

    esp_err_t rc = ESP_OK;
    size_t offset = 0;
    while (offset < sample_count) {
        const size_t count = (sample_count - offset) > MONO_CHUNK_SAMPLES ? MONO_CHUNK_SAMPLES : (sample_count - offset);
        for (size_t i = 0; i < count; i += 1) {
            const int16_t sample = pcm[offset + i];
            const int32_t out = (int32_t)sample << 16;
            stereo_frame_32[i * 2] = out;
            stereo_frame_32[i * 2 + 1] = out;
        }

        size_t written = 0;
        rc = i2s_channel_write(tx_chan, stereo_frame_32, count * 2 * sizeof(int32_t), &written, portMAX_DELAY);
        if (rc != ESP_OK) break;
        if (written != count * 2 * sizeof(int32_t)) {
            rc = ESP_FAIL;
            break;
        }
        offset += count;
    }

    if (audio_write_mutex != NULL) {
        xSemaphoreGive(audio_write_mutex);
    }
    return rc;
}

int szp_audio_mic_capture_start(void)
{
    ESP_RETURN_ON_ERROR(szp_audio_init(), TAG, "audio init");

    mic_capture_streaming = true;
    if (afe_handle != NULL && afe_data != NULL) {
        afe_handle->reset_buffer(afe_data);
    }
    afe_feed_fill_count = 0;
    afe_feed_since_fetch = 0;
    afe_output_pending_offset = 0;
    afe_output_pending_count = 0;
    raw_capture_log_count = 0;
    ESP_LOGI(TAG, "raw mic capture started");
    return ESP_OK;
}

int szp_audio_mic_read_i16(int16_t *mic0, int16_t *mic1, int16_t *ref, size_t sample_capacity, size_t *sample_count)
{
    if (sample_count != NULL) *sample_count = 0;
    if (mic0 == NULL || mic1 == NULL || ref == NULL || sample_count == NULL) return ESP_ERR_INVALID_ARG;
    if (!mic_capture_streaming || !audio_ready) return ESP_ERR_INVALID_STATE;
    if (sample_capacity == 0) return ESP_ERR_INVALID_SIZE;

    const size_t requested = sample_capacity > MONO_CHUNK_SAMPLES ? MONO_CHUNK_SAMPLES : sample_capacity;
    const size_t expected_bytes = requested * MIC_RX_CHANNELS * sizeof(int16_t);
    size_t bytes_read = 0;
    esp_err_t rc = i2s_channel_read(rx_chan, mic_raw_capture_buffer, expected_bytes, &bytes_read, pdMS_TO_TICKS(1000));
    const size_t frames_read = bytes_read / (MIC_RX_CHANNELS * sizeof(int16_t));
    if (frames_read == 0) return rc == ESP_OK ? ESP_ERR_TIMEOUT : rc;

    int16_t peaks[MIC_RX_CHANNELS] = {0};
    uint16_t saturations[MIC_RX_CHANNELS] = {0};

    for (size_t i = 0; i < frames_read; i += 1) {
        const int16_t raw_ref = mic_raw_capture_buffer[i * MIC_RX_CHANNELS];
        const int16_t mic_a = mic_raw_capture_buffer[i * MIC_RX_CHANNELS + 1];
        const int16_t mic_b = mic_raw_capture_buffer[i * MIC_RX_CHANNELS + 3];
        if (raw_capture_log_count < 8) {
            for (size_t lane = 0; lane < MIC_RX_CHANNELS; lane += 1) {
                const int16_t sample = mic_raw_capture_buffer[i * MIC_RX_CHANNELS + lane];
                const int16_t peak = peak_abs_i16(peaks[lane], sample);
                peaks[lane] = peak;
                if (peak_abs_i16(0, sample) >= TX_REF_SATURATION_THRESHOLD) {
                    saturations[lane] += 1;
                }
            }
        }
        ref[i] = raw_ref;
        mic0[i] = mic_a;
        mic1[i] = mic_b;
    }
    if (raw_capture_log_count < 8) {
        ESP_LOGI(TAG,
                 "raw rx peaks: l0=%d sat=%u l1=%d sat=%u l2=%d sat=%u l3=%d sat=%u",
                 peaks[0], saturations[0], peaks[1], saturations[1], peaks[2], saturations[2], peaks[3], saturations[3]);
        raw_capture_log_count += 1;
    }
    *sample_count = frames_read;
    if (rc != ESP_OK && frames_read < requested) {
        ESP_LOGD(TAG, "raw mic partial read: %u/%u frames rc=%s", (unsigned)frames_read, (unsigned)requested, esp_err_to_name(rc));
    }
    return ESP_OK;
}

int szp_audio_afe_process_i16(
    const int16_t *mic0,
    const int16_t *mic1,
    const int16_t *ref,
    size_t sample_count,
    int16_t *out,
    size_t out_capacity,
    size_t *out_count)
{
    if (out_count != NULL) *out_count = 0;
    if (mic0 == NULL || mic1 == NULL || ref == NULL || out == NULL || out_count == NULL) return ESP_ERR_INVALID_ARG;
    ESP_RETURN_ON_ERROR(init_afe(), TAG, "afe init");
    if (sample_count == 0) return ESP_OK;

    size_t produced = drain_pending_afe_output(out, out_capacity, 0);
    for (size_t i = 0; i < sample_count; i += 1) {
        const size_t feed_index = afe_feed_fill_count;
        afe_feed_buffer[feed_index * AFE_CHANNELS] = mic0[i];
        afe_feed_buffer[feed_index * AFE_CHANNELS + 1] = mic1[i];
        afe_feed_buffer[feed_index * AFE_CHANNELS + 2] = ref[i];
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

int szp_audio_mic_capture_stop(void)
{
    mic_capture_streaming = false;
    afe_feed_fill_count = 0;
    afe_feed_since_fetch = 0;
    afe_output_pending_offset = 0;
    afe_output_pending_count = 0;
    return ESP_OK;
}

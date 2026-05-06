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
#include "freertos/task.h"

#define SAMPLE_RATE_HZ 16000
#define I2S_MCLK_GPIO 38
#define I2S_BCLK_GPIO 14
#define I2S_WS_GPIO 13
#define I2S_DOUT_GPIO 45
#define I2S_DIN_GPIO 12
#define MONO_CHUNK_SAMPLES 256
#define MIC_INPUT_FORMAT "MR"
#define MIC_TASK_STACK_BYTES (8 * 1024)
#define MIC_AFE_TASK_PRIORITY 8
#define MIC_FEED_TASK_PRIORITY 7
#define MIC_FETCH_TASK_PRIORITY 6
#define MIC_RX_CHANNELS 4
#define AFE_MIC_CHANNELS 2
#define AFE_REF_CHANNELS 1
#define AFE_CHANNELS (AFE_MIC_CHANNELS + AFE_REF_CHANNELS)
#define MIC_OUTPUT_GAIN_NUM 3
#define MIC_OUTPUT_GAIN_DEN 1

static const char *TAG = "szp_audio";
static i2s_chan_handle_t tx_chan;
static i2s_chan_handle_t rx_chan;
static bool audio_ready;
static volatile bool mic_streaming;
static int32_t stereo_frame_32[MONO_CHUNK_SAMPLES * 2];
static const esp_afe_sr_iface_t *afe_handle;
static esp_afe_sr_data_t *afe_data;
static int16_t *afe_feed_buffer;
static int16_t *mic_rx_buffer;
static int16_t *mic_output_buffer;
static size_t afe_feed_sample_count;
static size_t afe_feed_byte_count;
static size_t mic_frame_count;
static size_t mic_output_sample_capacity;
static TaskHandle_t mic_feed_task;
static TaskHandle_t mic_fetch_task;
static SemaphoreHandle_t audio_write_mutex;

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
    free(mic_rx_buffer);
    mic_rx_buffer = NULL;
    free(mic_output_buffer);
    mic_output_buffer = NULL;
    afe_feed_sample_count = 0;
    afe_feed_byte_count = 0;
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
    afe_feed_byte_count = afe_feed_sample_count * sizeof(int16_t);
    afe_feed_buffer = calloc(afe_feed_sample_count, sizeof(int16_t));
    if (afe_feed_buffer == NULL) return fail_afe_init(ESP_ERR_NO_MEM);
    mic_frame_count = (size_t)chunk_samples;
    mic_rx_buffer = calloc(mic_frame_count * MIC_RX_CHANNELS, sizeof(int16_t));
    if (mic_rx_buffer == NULL) return fail_afe_init(ESP_ERR_NO_MEM);

    const int fetch_samples = afe_handle->get_fetch_chunksize(afe_data);
    if (fetch_samples <= 0) return fail_afe_init(ESP_FAIL);
    mic_output_sample_capacity = (size_t)fetch_samples;
    mic_output_buffer = calloc(mic_output_sample_capacity, sizeof(int16_t));
    if (mic_output_buffer == NULL) return fail_afe_init(ESP_ERR_NO_MEM);

    ESP_LOGI(TAG, "AFE initialized: feed=%d samples channels=%d fetch=%d", chunk_samples, channel_count, fetch_samples);
    return ESP_OK;
}

static void mic_feed_task_fn(void *arg)
{
    (void)arg;
    while (mic_streaming) {
        size_t bytes_read = 0;
        esp_err_t rc = i2s_channel_read(rx_chan, mic_rx_buffer, mic_frame_count * MIC_RX_CHANNELS * sizeof(int16_t), &bytes_read, pdMS_TO_TICKS(1000));
        if (!mic_streaming) break;
        if (rc != ESP_OK || bytes_read != mic_frame_count * MIC_RX_CHANNELS * sizeof(int16_t)) {
            if (rc != ESP_ERR_TIMEOUT) {
                ESP_LOGW(TAG, "read mic failed: %s bytes=%u", esp_err_to_name(rc), (unsigned)bytes_read);
            }
            continue;
        }
        for (size_t i = 0; i < mic_frame_count; i += 1) {
            const int16_t ref = mic_rx_buffer[i * MIC_RX_CHANNELS];
            afe_feed_buffer[i * AFE_CHANNELS] = mic_rx_buffer[i * MIC_RX_CHANNELS + 1];
            afe_feed_buffer[i * AFE_CHANNELS + 1] = mic_rx_buffer[i * MIC_RX_CHANNELS + 3];
            afe_feed_buffer[i * AFE_CHANNELS + 2] = ref;
        }
        if (afe_handle->feed(afe_data, afe_feed_buffer) < 0) {
            ESP_LOGW(TAG, "afe feed failed");
        }
    }
    mic_feed_task = NULL;
    vTaskDelete(NULL);
}

static int16_t apply_monitor_gain(int16_t sample)
{
    int32_t value = ((int32_t)sample * MIC_OUTPUT_GAIN_NUM) / MIC_OUTPUT_GAIN_DEN;
    if (value > INT16_MAX) return INT16_MAX;
    if (value < INT16_MIN) return INT16_MIN;
    return (int16_t)value;
}

static void mic_fetch_task_fn(void *arg)
{
    (void)arg;
    uint32_t logged_frames = 0;
    while (mic_streaming) {
        afe_fetch_result_t *result = afe_handle->fetch(afe_data);
        if (!mic_streaming) break;
        if (result == NULL || result->ret_value == ESP_FAIL || result->data == NULL || result->data_size <= 0) {
            continue;
        }
        const size_t sample_count = (size_t)result->data_size / sizeof(int16_t);
        if (sample_count > mic_output_sample_capacity) {
            ESP_LOGW(TAG, "mic output too large: %u samples", (unsigned)sample_count);
            continue;
        }
        for (size_t i = 0; i < sample_count; i += 1) {
            mic_output_buffer[i] = apply_monitor_gain(result->data[i]);
        }
        if (logged_frames < 3) {
            ESP_LOGI(TAG, "mic fetch output: %u samples", (unsigned)sample_count);
            logged_frames += 1;
        }
        esp_err_t rc = szp_audio_write_i16(mic_output_buffer, sample_count);
        if (rc != ESP_OK) {
            ESP_LOGW(TAG, "write mic output failed: %s", esp_err_to_name(rc));
        }
    }
    mic_fetch_task = NULL;
    vTaskDelete(NULL);
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

static void wait_mic_tasks_stopped(void)
{
    for (int i = 0; i < 50; i += 1) {
        if (mic_feed_task == NULL && mic_fetch_task == NULL) return;
        vTaskDelay(pdMS_TO_TICKS(20));
    }
    ESP_LOGW(TAG, "mic tasks did not stop cleanly");
}

int szp_audio_mic_start(void)
{
    ESP_RETURN_ON_ERROR(szp_audio_init(), TAG, "audio init");
    ESP_RETURN_ON_ERROR(init_afe(), TAG, "afe init");
    if (mic_streaming) return ESP_OK;

    if (afe_handle != NULL && afe_data != NULL) {
        afe_handle->reset_buffer(afe_data);
    }
    ESP_RETURN_ON_ERROR(szp_audio_set_pa(true), TAG, "enable pa");
    mic_streaming = true;
    if (mic_feed_task == NULL &&
        xTaskCreatePinnedToCore(mic_feed_task_fn, "chant_mic_feed", MIC_TASK_STACK_BYTES, NULL, MIC_FEED_TASK_PRIORITY, &mic_feed_task, 1) != pdPASS) {
        mic_streaming = false;
        return ESP_ERR_NO_MEM;
    }
    if (mic_fetch_task == NULL &&
        xTaskCreatePinnedToCore(mic_fetch_task_fn, "chant_mic_fetch", MIC_TASK_STACK_BYTES, NULL, MIC_FETCH_TASK_PRIORITY, &mic_fetch_task, 1) != pdPASS) {
        mic_streaming = false;
        if (afe_handle != NULL && afe_data != NULL) {
            afe_handle->reset_buffer(afe_data);
        }
        wait_mic_tasks_stopped();
        return ESP_ERR_NO_MEM;
    }
    ESP_LOGI(TAG, "mic stream started");
    return ESP_OK;
}

int szp_audio_mic_process_frame(void)
{
    return mic_streaming ? ESP_OK : ESP_ERR_INVALID_STATE;
}

int szp_audio_mic_stop(void)
{
    mic_streaming = false;
    if (afe_handle != NULL && afe_data != NULL) {
        afe_handle->reset_buffer(afe_data);
    }
    wait_mic_tasks_stopped();
    return ESP_OK;
}

int szp_audio_play_test_tone(uint32_t frequency_hz, uint32_t duration_ms)
{
    if (frequency_hz == 0) return ESP_ERR_INVALID_ARG;
    if (frequency_hz > SAMPLE_RATE_HZ / 2) return ESP_ERR_INVALID_ARG;
    ESP_RETURN_ON_ERROR(szp_audio_init(), TAG, "audio init");

    const uint32_t samples_total = (SAMPLE_RATE_HZ * duration_ms) / 1000;
    const uint32_t half_period = SAMPLE_RATE_HZ / (frequency_hz * 2);
    int16_t frame[256];
    uint32_t produced = 0;

    while (produced < samples_total) {
        const size_t count = (samples_total - produced) > 256 ? 256 : (size_t)(samples_total - produced);
        for (size_t i = 0; i < count; i += 1) {
            const uint32_t phase = (produced + i) / half_period;
            frame[i] = (phase & 1u) == 0 ? 9000 : -9000;
        }
        ESP_RETURN_ON_ERROR(szp_audio_write_i16(frame, count), TAG, "write tone");
        produced += count;
    }
    return ESP_OK;
}

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#include "driver/i2s_std.h"
#include "esp_check.h"
#include "esp_err.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"

#define MAX_MONO_CHUNK_SAMPLES 512
#define MAX_RX_CHANNELS 4
#define MAX_MIC_CHANNELS 2

typedef struct {
    int i2s_port;
    uint32_t sample_rate_hz;
    int mclk_gpio;
    int bclk_gpio;
    int ws_gpio;
    int dout_gpio;
    int din_gpio;
    int i2s_data_bit_width;
    int i2s_slot_mode;
    size_t mono_chunk_samples;
    size_t rx_channel_count;
    size_t mic_count;
    int mic0_lane;
    int mic1_lane;
    int ref_lane;
} espz_es8311_es7210_audio_config_t;

static const char *TAG = "espz_es8311_es7210_audio";

static espz_es8311_es7210_audio_config_t config;
static bool configured;
static bool audio_ready;
static bool mic_capture_streaming;
static i2s_chan_handle_t tx_chan;
static i2s_chan_handle_t rx_chan;
static int32_t stereo_frame_32[MAX_MONO_CHUNK_SAMPLES * 2];
static int16_t stereo_frame_16[MAX_MONO_CHUNK_SAMPLES * 2];
static int16_t mic_rx_buffer[MAX_MONO_CHUNK_SAMPLES * MAX_RX_CHANNELS];
static SemaphoreHandle_t audio_write_mutex;

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
    audio_ready = false;
}

static esp_err_t require_config(void)
{
    if (!configured) return ESP_ERR_INVALID_STATE;
    if (config.sample_rate_hz == 0) return ESP_ERR_INVALID_ARG;
    if (config.mono_chunk_samples == 0 || config.mono_chunk_samples > MAX_MONO_CHUNK_SAMPLES) return ESP_ERR_INVALID_ARG;
    if (config.rx_channel_count == 0 || config.rx_channel_count > MAX_RX_CHANNELS) return ESP_ERR_INVALID_ARG;
    if (config.mic_count == 0 || config.mic_count > MAX_MIC_CHANNELS) return ESP_ERR_INVALID_ARG;
    if (config.i2s_data_bit_width != 16 && config.i2s_data_bit_width != 32) return ESP_ERR_INVALID_ARG;
    if (config.i2s_slot_mode != 1 && config.i2s_slot_mode != 2) return ESP_ERR_INVALID_ARG;
    if (config.mic0_lane < 0 || (size_t)config.mic0_lane >= config.rx_channel_count) return ESP_ERR_INVALID_ARG;
    if (config.mic_count > 1 && (config.mic1_lane < 0 || (size_t)config.mic1_lane >= config.rx_channel_count)) return ESP_ERR_INVALID_ARG;
    if (config.ref_lane >= 0 && (size_t)config.ref_lane >= config.rx_channel_count) return ESP_ERR_INVALID_ARG;
    return ESP_OK;
}

static esp_err_t init_i2s(void)
{
    ESP_RETURN_ON_ERROR(require_config(), TAG, "audio config");
    if (tx_chan != NULL && rx_chan != NULL) return ESP_OK;
    if (audio_write_mutex == NULL) {
        audio_write_mutex = xSemaphoreCreateMutex();
        if (audio_write_mutex == NULL) return ESP_ERR_NO_MEM;
    }

    i2s_chan_config_t chan_cfg = I2S_CHANNEL_DEFAULT_CONFIG(config.i2s_port, I2S_ROLE_MASTER);
    chan_cfg.auto_clear = true;
    esp_err_t rc = i2s_new_channel(&chan_cfg, &tx_chan, &rx_chan);
    if (rc != ESP_OK) {
        deinit_i2s_channels();
        ESP_RETURN_ON_ERROR(rc, TAG, "new i2s channels");
    }

    i2s_data_bit_width_t data_bit_width;
    switch (config.i2s_data_bit_width) {
    case 16:
        data_bit_width = I2S_DATA_BIT_WIDTH_16BIT;
        break;
    case 32:
        data_bit_width = I2S_DATA_BIT_WIDTH_32BIT;
        break;
    default:
        return ESP_ERR_INVALID_ARG;
    }

    i2s_slot_mode_t slot_mode;
    switch (config.i2s_slot_mode) {
    case 1:
        slot_mode = I2S_SLOT_MODE_MONO;
        break;
    case 2:
        slot_mode = I2S_SLOT_MODE_STEREO;
        break;
    default:
        return ESP_ERR_INVALID_ARG;
    }

    i2s_std_config_t std_cfg = {
        .clk_cfg = I2S_STD_CLK_DEFAULT_CONFIG(config.sample_rate_hz),
        .slot_cfg = I2S_STD_PHILIPS_SLOT_DEFAULT_CONFIG(data_bit_width, slot_mode),
        .gpio_cfg = {
            .mclk = (gpio_num_t)config.mclk_gpio,
            .bclk = (gpio_num_t)config.bclk_gpio,
            .ws = (gpio_num_t)config.ws_gpio,
            .dout = (gpio_num_t)config.dout_gpio,
            .din = (gpio_num_t)config.din_gpio,
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
        ESP_RETURN_ON_ERROR(rc, TAG, "init i2s tx std");
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

int espz_es8311_es7210_audio_configure(const espz_es8311_es7210_audio_config_t *new_config)
{
    if (new_config == NULL) return ESP_ERR_INVALID_ARG;
    if (audio_ready) return ESP_ERR_INVALID_STATE;
    config = *new_config;
    configured = true;
    return require_config();
}

int espz_es8311_es7210_audio_init(void)
{
    if (audio_ready) return ESP_OK;
    ESP_RETURN_ON_ERROR(init_i2s(), TAG, "i2s init");
    audio_ready = true;
    return ESP_OK;
}

void espz_es8311_es7210_audio_deinit(void)
{
    mic_capture_streaming = false;
    deinit_i2s_channels();
    if (audio_write_mutex != NULL) {
        vSemaphoreDelete(audio_write_mutex);
        audio_write_mutex = NULL;
    }
    configured = false;
}

int espz_es8311_es7210_audio_write_i16(const int16_t *pcm, size_t sample_count)
{
    if (!audio_ready || pcm == NULL) return ESP_ERR_INVALID_STATE;
    if (audio_write_mutex != NULL && xSemaphoreTake(audio_write_mutex, portMAX_DELAY) != pdTRUE) {
        return ESP_ERR_TIMEOUT;
    }

    esp_err_t rc = ESP_OK;
    size_t offset = 0;
    while (offset < sample_count) {
        const size_t count = (sample_count - offset) > config.mono_chunk_samples ? config.mono_chunk_samples : (sample_count - offset);
        size_t written = 0;
        size_t expected = 0;
        if (config.i2s_data_bit_width == 16) {
            for (size_t i = 0; i < count; i += 1) {
                const int16_t sample = pcm[offset + i];
                stereo_frame_16[i * 2] = sample;
                stereo_frame_16[i * 2 + 1] = sample;
            }
            expected = count * 2 * sizeof(int16_t);
            rc = i2s_channel_write(tx_chan, stereo_frame_16, expected, &written, portMAX_DELAY);
        } else {
            for (size_t i = 0; i < count; i += 1) {
                const int16_t sample = pcm[offset + i];
                const int32_t out = (int32_t)sample << 16;
                stereo_frame_32[i * 2] = out;
                stereo_frame_32[i * 2 + 1] = out;
            }
            expected = count * 2 * sizeof(int32_t);
            rc = i2s_channel_write(tx_chan, stereo_frame_32, expected, &written, portMAX_DELAY);
        }
        if (rc != ESP_OK) break;
        if (written != expected) {
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

int espz_es8311_es7210_audio_write_raw(const uint8_t *data, size_t byte_count, size_t *bytes_written)
{
    if (bytes_written != NULL) *bytes_written = 0;
    if (!audio_ready || data == NULL || bytes_written == NULL) return ESP_ERR_INVALID_STATE;
    if (byte_count == 0) return ESP_OK;
    if (audio_write_mutex != NULL && xSemaphoreTake(audio_write_mutex, portMAX_DELAY) != pdTRUE) {
        return ESP_ERR_TIMEOUT;
    }

    esp_err_t rc = i2s_channel_write(tx_chan, data, byte_count, bytes_written, portMAX_DELAY);
    if (audio_write_mutex != NULL) {
        xSemaphoreGive(audio_write_mutex);
    }
    return rc;
}

int espz_es8311_es7210_audio_read_raw(uint8_t *data, size_t byte_capacity, size_t *bytes_read)
{
    if (bytes_read != NULL) *bytes_read = 0;
    if (!mic_capture_streaming || !audio_ready || data == NULL || bytes_read == NULL) return ESP_ERR_INVALID_STATE;
    if (byte_capacity == 0) return ESP_OK;

    esp_err_t rc = i2s_channel_read(rx_chan, data, byte_capacity, bytes_read, pdMS_TO_TICKS(1000));
    if (*bytes_read == 0 && rc == ESP_OK) return ESP_ERR_TIMEOUT;
    return rc;
}

int espz_es8311_es7210_audio_mic_capture_start(void)
{
    ESP_RETURN_ON_ERROR(espz_es8311_es7210_audio_init(), TAG, "audio init");
    mic_capture_streaming = true;
    return ESP_OK;
}

int espz_es8311_es7210_audio_mic_capture_stop(void)
{
    mic_capture_streaming = false;
    return ESP_OK;
}

int espz_es8311_es7210_audio_mic_read_i16(
    int16_t *mic0,
    int16_t *mic1,
    int16_t *ref,
    size_t sample_capacity,
    size_t *sample_count)
{
    if (sample_count != NULL) *sample_count = 0;
    if (mic0 == NULL || ref == NULL || sample_count == NULL) return ESP_ERR_INVALID_ARG;
    if (config.mic_count > 1 && mic1 == NULL) return ESP_ERR_INVALID_ARG;
    if (!mic_capture_streaming || !audio_ready) return ESP_ERR_INVALID_STATE;
    if (config.ref_lane < 0) return ESP_ERR_INVALID_STATE;
    if (sample_capacity == 0) return ESP_ERR_INVALID_SIZE;

    const size_t requested = sample_capacity > config.mono_chunk_samples ? config.mono_chunk_samples : sample_capacity;
    const size_t expected_bytes = requested * config.rx_channel_count * sizeof(int16_t);
    size_t bytes_read = 0;
    esp_err_t rc = i2s_channel_read(rx_chan, mic_rx_buffer, expected_bytes, &bytes_read, pdMS_TO_TICKS(1000));
    const size_t frames_read = bytes_read / (config.rx_channel_count * sizeof(int16_t));
    if (frames_read == 0) return rc == ESP_OK ? ESP_ERR_TIMEOUT : rc;

    for (size_t i = 0; i < frames_read; i += 1) {
        ref[i] = mic_rx_buffer[i * config.rx_channel_count + (size_t)config.ref_lane];
        mic0[i] = mic_rx_buffer[i * config.rx_channel_count + (size_t)config.mic0_lane];
        if (config.mic_count > 1) {
            mic1[i] = mic_rx_buffer[i * config.rx_channel_count + (size_t)config.mic1_lane];
        }
    }

    *sample_count = frames_read;
    return ESP_OK;
}

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "driver/i2s_std.h"
#include "esp_check.h"
#include "esp_err.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"

#define MAX_MONO_CHUNK_SAMPLES 960
#define MAX_RX_CHANNELS 2

typedef struct {
    int i2s_port;
    uint32_t sample_rate_hz;
    int mclk_gpio;
    int bclk_gpio;
    int ws_gpio;
    int dout_gpio;
    int din_gpio;
    size_t mono_chunk_samples;
    size_t rx_channel_count;
    int mic_lane;
    int ref_lane;
} espz_es8311_audio_config_t;

static const char *TAG = "espz_es8311_audio";

static espz_es8311_audio_config_t config;
static bool configured;
static bool audio_ready;
static bool mic_capture_streaming;
static i2s_chan_handle_t tx_chan;
static i2s_chan_handle_t rx_chan;
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
    if (config.mic_lane < 0 || (size_t)config.mic_lane >= config.rx_channel_count) return ESP_ERR_INVALID_ARG;
    if (config.ref_lane >= 0) {
        if ((size_t)config.ref_lane >= config.rx_channel_count) return ESP_ERR_INVALID_ARG;
        if (config.ref_lane == config.mic_lane) return ESP_ERR_INVALID_ARG;
    }
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

    i2s_std_config_t std_cfg = {
        .clk_cfg = I2S_STD_CLK_DEFAULT_CONFIG(config.sample_rate_hz),
        .slot_cfg = I2S_STD_PHILIPS_SLOT_DEFAULT_CONFIG(I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_STEREO),
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

int espz_es8311_audio_configure(const espz_es8311_audio_config_t *new_config)
{
    if (new_config == NULL) return ESP_ERR_INVALID_ARG;
    if (audio_ready) return ESP_ERR_INVALID_STATE;
    config = *new_config;
    configured = true;
    return require_config();
}

int espz_es8311_audio_init(void)
{
    if (audio_ready) return ESP_OK;
    ESP_RETURN_ON_ERROR(init_i2s(), TAG, "i2s init");
    audio_ready = true;
    return ESP_OK;
}

void espz_es8311_audio_deinit(void)
{
    mic_capture_streaming = false;
    deinit_i2s_channels();
    if (audio_write_mutex != NULL) {
        vSemaphoreDelete(audio_write_mutex);
        audio_write_mutex = NULL;
    }
    configured = false;
}

int espz_es8311_audio_write_raw(const uint8_t *data, size_t byte_count, size_t *bytes_written)
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

int espz_es8311_audio_read_raw(uint8_t *data, size_t byte_capacity, size_t *bytes_read)
{
    if (bytes_read != NULL) *bytes_read = 0;
    if (!mic_capture_streaming || !audio_ready || data == NULL || bytes_read == NULL) return ESP_ERR_INVALID_STATE;
    if (byte_capacity == 0) return ESP_OK;

    esp_err_t rc = i2s_channel_read(rx_chan, data, byte_capacity, bytes_read, pdMS_TO_TICKS(1000));
    if (*bytes_read == 0 && rc == ESP_OK) return ESP_ERR_TIMEOUT;
    return rc;
}

int espz_es8311_audio_mic_capture_start(void)
{
    ESP_RETURN_ON_ERROR(espz_es8311_audio_init(), TAG, "audio init");
    mic_capture_streaming = true;
    return ESP_OK;
}

int espz_es8311_audio_mic_capture_stop(void)
{
    mic_capture_streaming = false;
    return ESP_OK;
}

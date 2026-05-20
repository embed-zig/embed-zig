#include "wv_board.h"

#include "driver/gpio.h"
#include "driver/i2s_std.h"
#include "esp_check.h"
#include "esp_err.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"

#define SAMPLE_RATE_HZ 16000
#define I2S_PORT I2S_NUM_0
#define I2S_MCLK_GPIO GPIO_NUM_16
#define I2S_BCLK_GPIO GPIO_NUM_9
#define I2S_WS_GPIO GPIO_NUM_45
#define I2S_DOUT_GPIO GPIO_NUM_8
#define I2S_DIN_GPIO GPIO_NUM_10
#define PA_GPIO GPIO_NUM_46
#define MONO_CHUNK_SAMPLES 256

static const char *TAG = "wv_audio";
static i2s_chan_handle_t tx_chan;
static i2s_chan_handle_t rx_chan;
static bool audio_ready;
static bool mic_capture_streaming;
static int16_t stereo_frame[MONO_CHUNK_SAMPLES * 2];
static int16_t mic_rx_buffer[MONO_CHUNK_SAMPLES * 2];
static SemaphoreHandle_t audio_write_mutex;

static esp_err_t init_pa(void)
{
    gpio_config_t config = {
        .pin_bit_mask = 1ULL << PA_GPIO,
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    ESP_RETURN_ON_ERROR(gpio_config(&config), TAG, "configure pa");
    return gpio_set_level(PA_GPIO, 0);
}

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

static esp_err_t init_i2s(void)
{
    if (tx_chan != NULL && rx_chan != NULL) return ESP_OK;
    if (audio_write_mutex == NULL) {
        audio_write_mutex = xSemaphoreCreateMutex();
        if (audio_write_mutex == NULL) return ESP_ERR_NO_MEM;
    }

    i2s_chan_config_t chan_cfg = I2S_CHANNEL_DEFAULT_CONFIG(I2S_PORT, I2S_ROLE_MASTER);
    chan_cfg.auto_clear = true;
    esp_err_t rc = i2s_new_channel(&chan_cfg, &tx_chan, &rx_chan);
    if (rc != ESP_OK) {
        deinit_i2s_channels();
        ESP_RETURN_ON_ERROR(rc, TAG, "new i2s channels");
    }

    i2s_std_config_t std_cfg = {
        .clk_cfg = I2S_STD_CLK_DEFAULT_CONFIG(SAMPLE_RATE_HZ),
        .slot_cfg = I2S_STD_PHILIPS_SLOT_DEFAULT_CONFIG(I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_STEREO),
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

int wv_audio_init(void)
{
    if (audio_ready) return ESP_OK;

    ESP_RETURN_ON_ERROR(init_pa(), TAG, "pa init");
    ESP_RETURN_ON_ERROR(init_i2s(), TAG, "i2s init");
    audio_ready = true;
    return ESP_OK;
}

int wv_audio_set_pa(bool enabled)
{
    ESP_RETURN_ON_ERROR(init_pa(), TAG, "pa init");
    return gpio_set_level(PA_GPIO, enabled ? 1 : 0);
}

int wv_audio_write_i16(const int16_t *pcm, size_t sample_count)
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
            stereo_frame[i * 2] = sample;
            stereo_frame[i * 2 + 1] = sample;
        }

        size_t written = 0;
        rc = i2s_channel_write(tx_chan, stereo_frame, count * 2 * sizeof(int16_t), &written, portMAX_DELAY);
        if (rc != ESP_OK) break;
        if (written != count * 2 * sizeof(int16_t)) {
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

int wv_audio_mic_capture_start(void)
{
    ESP_RETURN_ON_ERROR(wv_audio_init(), TAG, "audio init");
    mic_capture_streaming = true;
    return ESP_OK;
}

int wv_audio_mic_read_i16(int16_t *mic0, size_t sample_capacity, size_t *sample_count)
{
    if (sample_count != NULL) *sample_count = 0;
    if (mic0 == NULL || sample_count == NULL) return ESP_ERR_INVALID_ARG;
    if (!mic_capture_streaming || !audio_ready) return ESP_ERR_INVALID_STATE;
    if (sample_capacity == 0) return ESP_ERR_INVALID_SIZE;

    const size_t requested = sample_capacity > MONO_CHUNK_SAMPLES ? MONO_CHUNK_SAMPLES : sample_capacity;
    const size_t expected_bytes = requested * 2 * sizeof(int16_t);
    size_t bytes_read = 0;
    esp_err_t rc = i2s_channel_read(rx_chan, mic_rx_buffer, expected_bytes, &bytes_read, pdMS_TO_TICKS(1000));
    const size_t frames_read = bytes_read / (2 * sizeof(int16_t));
    if (frames_read == 0) return rc == ESP_OK ? ESP_ERR_TIMEOUT : rc;

    for (size_t i = 0; i < frames_read; i += 1) {
        mic0[i] = mic_rx_buffer[i * 2];
    }

    *sample_count = frames_read;
    return ESP_OK;
}

int wv_audio_mic_capture_stop(void)
{
    mic_capture_streaming = false;
    return ESP_OK;
}

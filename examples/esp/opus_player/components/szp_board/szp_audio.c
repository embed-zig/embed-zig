#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#include "driver/i2s_std.h"
#include "esp_check.h"
#include "esp_err.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#define SAMPLE_RATE_HZ 16000
#define I2S_MCLK_GPIO 38
#define I2S_BCLK_GPIO 14
#define I2S_WS_GPIO 13
#define I2S_DOUT_GPIO 45
#define I2S_DIN_GPIO 12
#define MONO_CHUNK_SAMPLES 256

static const char *TAG = "szp_audio";
static i2s_chan_handle_t tx_chan;
static bool audio_ready;
static int16_t stereo_frame[MONO_CHUNK_SAMPLES * 2];

int szp_pca9557_set_pa(bool enabled);

static esp_err_t init_i2s(void)
{
    if (tx_chan != NULL) return ESP_OK;

    i2s_chan_config_t chan_cfg = I2S_CHANNEL_DEFAULT_CONFIG(I2S_NUM_1, I2S_ROLE_MASTER);
    chan_cfg.auto_clear = true;
    ESP_RETURN_ON_ERROR(i2s_new_channel(&chan_cfg, &tx_chan, NULL), TAG, "new i2s tx channel");

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
    ESP_RETURN_ON_ERROR(i2s_channel_init_std_mode(tx_chan, &std_cfg), TAG, "init i2s std");
    return i2s_channel_enable(tx_chan);
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

    size_t offset = 0;
    while (offset < sample_count) {
        const size_t count = (sample_count - offset) > MONO_CHUNK_SAMPLES ? MONO_CHUNK_SAMPLES : (sample_count - offset);
        for (size_t i = 0; i < count; i += 1) {
            const int16_t sample = pcm[offset + i];
            stereo_frame[i * 2] = sample;
            stereo_frame[i * 2 + 1] = sample;
        }

        size_t written = 0;
        ESP_RETURN_ON_ERROR(
            i2s_channel_write(tx_chan, stereo_frame, count * 2 * sizeof(int16_t), &written, portMAX_DELAY),
            TAG,
            "write pcm"
        );
        if (written != count * 2 * sizeof(int16_t)) return ESP_FAIL;
        offset += count;
    }

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

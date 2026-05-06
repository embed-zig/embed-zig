#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#include "driver/i2s_std.h"
#include "esp_check.h"
#include "esp_err.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#define ES8311_ADDR 0x18
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

int szp_i2c_write_reg(uint8_t address, uint8_t reg, uint8_t value);
int szp_i2c_read_reg(uint8_t address, uint8_t reg, uint8_t *value);
int szp_pca9557_set_pa(bool enabled);

static esp_err_t es8311_write(uint8_t reg, uint8_t value)
{
    return szp_i2c_write_reg(ES8311_ADDR, reg, value);
}

static esp_err_t es8311_read(uint8_t reg, uint8_t *value)
{
    return szp_i2c_read_reg(ES8311_ADDR, reg, value);
}

static esp_err_t es8311_update(uint8_t reg, uint8_t mask, uint8_t value)
{
    uint8_t regv = 0;
    ESP_RETURN_ON_ERROR(es8311_read(reg, &regv), TAG, "read update reg");
    regv = (uint8_t)((regv & (uint8_t)~mask) | (value & mask));
    return es8311_write(reg, regv);
}

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

static esp_err_t init_es8311(void)
{
    uint8_t chip_id1 = 0;
    uint8_t chip_id2 = 0;
    ESP_RETURN_ON_ERROR(es8311_read(0xfd, &chip_id1), TAG, "read chip id1");
    ESP_RETURN_ON_ERROR(es8311_read(0xfe, &chip_id2), TAG, "read chip id2");
    if (chip_id1 != 0x83 || chip_id2 != 0x11) {
        ESP_LOGW(TAG, "unexpected ES8311 id: 0x%02x 0x%02x", chip_id1, chip_id2);
    }

    ESP_RETURN_ON_ERROR(es8311_write(0x44, 0x08), TAG, "gpio44 filter");
    ESP_RETURN_ON_ERROR(es8311_write(0x44, 0x08), TAG, "gpio44 filter");
    ESP_RETURN_ON_ERROR(es8311_write(0x01, 0x30), TAG, "clk init");
    ESP_RETURN_ON_ERROR(es8311_write(0x02, 0x00), TAG, "clk2 init");
    ESP_RETURN_ON_ERROR(es8311_write(0x03, 0x10), TAG, "clk3 init");
    ESP_RETURN_ON_ERROR(es8311_write(0x16, 0x24), TAG, "adc gain");
    ESP_RETURN_ON_ERROR(es8311_write(0x04, 0x10), TAG, "clk4 init");
    ESP_RETURN_ON_ERROR(es8311_write(0x05, 0x00), TAG, "clk5 init");
    ESP_RETURN_ON_ERROR(es8311_write(0x0b, 0x00), TAG, "sys0b init");
    ESP_RETURN_ON_ERROR(es8311_write(0x0c, 0x00), TAG, "sys0c init");
    ESP_RETURN_ON_ERROR(es8311_write(0x10, 0x1f), TAG, "sys10 init");
    ESP_RETURN_ON_ERROR(es8311_write(0x11, 0x7f), TAG, "sys11 init");
    ESP_RETURN_ON_ERROR(es8311_write(0x00, 0x80), TAG, "reset csm");
    ESP_RETURN_ON_ERROR(es8311_update(0x00, 0x40, 0x00), TAG, "slave mode");
    ESP_RETURN_ON_ERROR(es8311_write(0x01, 0x3f), TAG, "clock on");
    ESP_RETURN_ON_ERROR(es8311_update(0x06, 0x20, 0x00), TAG, "bclk polarity");
    ESP_RETURN_ON_ERROR(es8311_write(0x13, 0x10), TAG, "sys13 init");
    ESP_RETURN_ON_ERROR(es8311_write(0x1b, 0x0a), TAG, "adc1b init");
    ESP_RETURN_ON_ERROR(es8311_write(0x1c, 0x6a), TAG, "adc1c init");
    ESP_RETURN_ON_ERROR(es8311_write(0x44, 0x58), TAG, "dac ref on");

    ESP_RETURN_ON_ERROR(es8311_write(0x02, 0x00), TAG, "16k clk2");
    ESP_RETURN_ON_ERROR(es8311_write(0x05, 0x00), TAG, "16k clk5");
    ESP_RETURN_ON_ERROR(es8311_write(0x03, 0x10), TAG, "16k adc osr");
    ESP_RETURN_ON_ERROR(es8311_write(0x04, 0x20), TAG, "16k dac osr");
    ESP_RETURN_ON_ERROR(es8311_write(0x07, 0x00), TAG, "16k lrck high");
    ESP_RETURN_ON_ERROR(es8311_write(0x08, 0xff), TAG, "16k lrck low");
    ESP_RETURN_ON_ERROR(es8311_update(0x06, 0x1f, 0x03), TAG, "16k bclk div");

    ESP_RETURN_ON_ERROR(es8311_update(0x09, 0x1c, 0x0c), TAG, "dac 16-bit");
    ESP_RETURN_ON_ERROR(es8311_update(0x0a, 0x1c, 0x0c), TAG, "adc 16-bit");
    ESP_RETURN_ON_ERROR(es8311_update(0x09, 0x03, 0x00), TAG, "dac i2s");
    ESP_RETURN_ON_ERROR(es8311_update(0x0a, 0x03, 0x00), TAG, "adc i2s");

    ESP_RETURN_ON_ERROR(es8311_write(0x17, 0xbf), TAG, "adc volume");
    ESP_RETURN_ON_ERROR(es8311_write(0x0e, 0x02), TAG, "adc analog");
    ESP_RETURN_ON_ERROR(es8311_write(0x12, 0x00), TAG, "dac enable");
    ESP_RETURN_ON_ERROR(es8311_write(0x14, 0x1a), TAG, "sys14 startup");
    ESP_RETURN_ON_ERROR(es8311_update(0x14, 0x40, 0x00), TAG, "digital mic off");
    ESP_RETURN_ON_ERROR(es8311_write(0x0d, 0x01), TAG, "analog power");
    ESP_RETURN_ON_ERROR(es8311_write(0x15, 0x40), TAG, "adc startup");
    ESP_RETURN_ON_ERROR(es8311_write(0x37, 0x08), TAG, "dac startup");
    ESP_RETURN_ON_ERROR(es8311_write(0x45, 0x00), TAG, "gp45");
    ESP_RETURN_ON_ERROR(es8311_write(0x32, 0xb0), TAG, "dac volume");
    ESP_RETURN_ON_ERROR(es8311_update(0x31, 0x60, 0x00), TAG, "dac unmute");
    return ESP_OK;
}

int szp_audio_init(void)
{
    if (audio_ready) return ESP_OK;

    ESP_RETURN_ON_ERROR(init_i2s(), TAG, "i2s init");
    ESP_RETURN_ON_ERROR(init_es8311(), TAG, "es8311 init");
    ESP_RETURN_ON_ERROR(szp_pca9557_set_pa(true), TAG, "pa enable");
    audio_ready = true;
    return ESP_OK;
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

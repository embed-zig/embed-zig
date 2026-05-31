#include <stdint.h>

#include "esp_check.h"
#include "esp_log.h"
#include "led_strip.h"

#define DEVKIT_LED_STRIP_GPIO 48
#define DEVKIT_LED_STRIP_COUNT 1

static const char *TAG = "devkit_led_strip";
static led_strip_handle_t s_led_strip;

static uint8_t scale_channel(uint8_t value, uint8_t scale)
{
    return (uint8_t)(((uint16_t)value * scale) / 255);
}

static void devkit_led_strip_map_rgb(uint8_t r, uint8_t g, uint8_t b, uint8_t *out_r, uint8_t *out_g, uint8_t *out_b)
{
    /*
     * The app layer speaks logical RGB. The onboard DevKit LED is warmer than
     * that logical space, so keep the adaptation here in the board binding.
     */
    *out_r = scale_channel(r, 180);
    *out_g = scale_channel(g, 190);
    *out_b = b;
}

int devkit_led_strip_init(void)
{
    if (s_led_strip != NULL) {
        return ESP_OK;
    }

    led_strip_config_t strip_config = {
        .strip_gpio_num = DEVKIT_LED_STRIP_GPIO,
        .max_leds = DEVKIT_LED_STRIP_COUNT,
    };
    led_strip_rmt_config_t rmt_config = {
        .resolution_hz = 10 * 1000 * 1000,
        .flags.with_dma = false,
    };

    ESP_RETURN_ON_ERROR(led_strip_new_rmt_device(&strip_config, &rmt_config, &s_led_strip), TAG, "create led strip");
    return led_strip_clear(s_led_strip);
}

int devkit_led_strip_set_rgb(uint8_t r, uint8_t g, uint8_t b)
{
    ESP_RETURN_ON_FALSE(s_led_strip != NULL, ESP_ERR_INVALID_STATE, TAG, "led strip not initialized");
    uint8_t mapped_r = 0;
    uint8_t mapped_g = 0;
    uint8_t mapped_b = 0;
    devkit_led_strip_map_rgb(r, g, b, &mapped_r, &mapped_g, &mapped_b);
    ESP_LOGI(TAG, "set rgb logical=(%u,%u,%u) mapped=(%u,%u,%u)",
             (unsigned)r,
             (unsigned)g,
             (unsigned)b,
             (unsigned)mapped_r,
             (unsigned)mapped_g,
             (unsigned)mapped_b);
    ESP_RETURN_ON_ERROR(led_strip_set_pixel(s_led_strip, 0, mapped_r, mapped_g, mapped_b), TAG, "set led pixel");
    return led_strip_refresh(s_led_strip);
}

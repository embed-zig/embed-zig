#include <stdint.h>

#include "esp_check.h"
#include "led_strip.h"

#define BLINK_GPIO_NUM 48

static const char *TAG = "blink_component";
static led_strip_handle_t s_led_strip;

int esp_example_blink_init(void)
{
    if (s_led_strip != NULL) {
        return ESP_OK;
    }

    led_strip_config_t strip_config = {
        .strip_gpio_num = BLINK_GPIO_NUM,
        .max_leds = 1,
    };
    led_strip_rmt_config_t rmt_config = {
        .resolution_hz = 10 * 1000 * 1000,
        .flags.with_dma = false,
    };

    ESP_RETURN_ON_ERROR(led_strip_new_rmt_device(&strip_config, &rmt_config, &s_led_strip), TAG, "create led strip");
    return led_strip_clear(s_led_strip);
}

int esp_example_blink_set_rgb(uint8_t r, uint8_t g, uint8_t b)
{
    ESP_RETURN_ON_FALSE(s_led_strip != NULL, ESP_ERR_INVALID_STATE, TAG, "led strip not initialized");
    ESP_RETURN_ON_ERROR(led_strip_set_pixel(s_led_strip, 0, r, g, b), TAG, "set led pixel");
    return led_strip_refresh(s_led_strip);
}

int esp_example_blink_clear(void)
{
    ESP_RETURN_ON_FALSE(s_led_strip != NULL, ESP_ERR_INVALID_STATE, TAG, "led strip not initialized");
    return led_strip_clear(s_led_strip);
}

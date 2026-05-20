#include "wv_board.h"

#include "driver/gpio.h"
#include "esp_check.h"

#define WV_POWER_BUTTON_GPIO GPIO_NUM_0

static const char *TAG = "wv_power_button";
static bool s_button_initialized;

int wv_power_button_init(void)
{
    if (s_button_initialized) {
        return ESP_OK;
    }

    gpio_config_t config = {
        .pin_bit_mask = 1ULL << WV_POWER_BUTTON_GPIO,
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_ENABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };

    ESP_RETURN_ON_ERROR(gpio_config(&config), TAG, "configure power button");
    s_button_initialized = true;
    return ESP_OK;
}

bool wv_power_button_pressed(void)
{
    if (!s_button_initialized) {
        if (wv_power_button_init() != ESP_OK) {
            return false;
        }
    }

    return gpio_get_level(WV_POWER_BUTTON_GPIO) == 0;
}

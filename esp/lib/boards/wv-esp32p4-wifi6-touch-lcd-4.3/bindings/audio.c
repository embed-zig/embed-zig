#include "wv_p4_board.h"

#include "driver/gpio.h"
#include "esp_check.h"
#include "esp_err.h"
#include "esp_log.h"

#define PA_GPIO GPIO_NUM_53

static const char *TAG = "wv_p4_audio";

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

int wv_p4_audio_set_pa(bool enabled)
{
    ESP_RETURN_ON_ERROR(init_pa(), TAG, "pa init");
    return gpio_set_level(PA_GPIO, enabled ? 1 : 0);
}

#include "szp_board.h"

#include "driver/gpio.h"
#include "esp_check.h"

#define BUTTON_GPIO GPIO_NUM_0

int szp_button_init(void)
{
    gpio_config_t cfg = {
        .pin_bit_mask = 1ULL << BUTTON_GPIO,
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_ENABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    return gpio_config(&cfg);
}

bool szp_button_read_raw(void)
{
    return gpio_get_level(BUTTON_GPIO) == 0;
}

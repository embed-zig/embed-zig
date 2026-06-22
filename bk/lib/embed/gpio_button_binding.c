#include <stdint.h>

#include <common/bk_err.h>
#include <driver/gpio.h>
#include "gpio_driver.h"

#define BK_EMBED_GPIO_BUTTON_OK 0
#define BK_EMBED_GPIO_BUTTON_INVALID_ARG 1
#define BK_EMBED_GPIO_BUTTON_UNEXPECTED 9

static int map_gpio_rc(bk_err_t rc)
{
    if (rc == BK_OK) {
        return BK_EMBED_GPIO_BUTTON_OK;
    }
    if (rc == BK_ERR_GPIO_CHAN_ID || rc == BK_ERR_GPIO_INVALID_ID || rc == BK_ERR_PARAM) {
        return BK_EMBED_GPIO_BUTTON_INVALID_ARG;
    }
    return BK_EMBED_GPIO_BUTTON_UNEXPECTED;
}

int bk_embed_gpio_active_low_button_init(uint32_t gpio_id)
{
    gpio_dev_unmap((gpio_id_t)gpio_id);

    int rc = map_gpio_rc(bk_gpio_disable_output((gpio_id_t)gpio_id));
    if (rc != BK_EMBED_GPIO_BUTTON_OK) {
        return rc;
    }
    rc = map_gpio_rc(bk_gpio_enable_input((gpio_id_t)gpio_id));
    if (rc != BK_EMBED_GPIO_BUTTON_OK) {
        return rc;
    }
    rc = map_gpio_rc(bk_gpio_enable_pull((gpio_id_t)gpio_id));
    if (rc != BK_EMBED_GPIO_BUTTON_OK) {
        return rc;
    }
    rc = map_gpio_rc(bk_gpio_pull_up((gpio_id_t)gpio_id));
    if (rc != BK_EMBED_GPIO_BUTTON_OK) {
        return rc;
    }

    return BK_EMBED_GPIO_BUTTON_OK;
}

int bk_embed_gpio_active_low_button_is_pressed(uint32_t gpio_id, uint32_t *pressed)
{
    if (pressed == 0) {
        return BK_EMBED_GPIO_BUTTON_INVALID_ARG;
    }

    *pressed = bk_gpio_get_input((gpio_id_t)gpio_id) ? 0u : 1u;
    return BK_EMBED_GPIO_BUTTON_OK;
}

int bk_embed_gpio_read_input(uint32_t gpio_id, uint32_t *value)
{
    if (value == 0) {
        return BK_EMBED_GPIO_BUTTON_INVALID_ARG;
    }

    *value = bk_gpio_get_input((gpio_id_t)gpio_id) ? 1u : 0u;
    return BK_EMBED_GPIO_BUTTON_OK;
}

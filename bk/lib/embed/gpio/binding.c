#include <stdint.h>

#include <common/bk_err.h>
#include <driver/gpio.h>
#include "gpio_driver.h"

#define BK_EMBED_GPIO_OK 0
#define BK_EMBED_GPIO_INVALID_ARG 1
#define BK_EMBED_GPIO_UNSUPPORTED 2
#define BK_EMBED_GPIO_UNEXPECTED 9

static int map_gpio_rc(bk_err_t rc)
{
    if (rc == BK_OK) {
        return BK_EMBED_GPIO_OK;
    }
    if (rc == BK_ERR_GPIO_CHAN_ID || rc == BK_ERR_GPIO_INVALID_ID || rc == BK_ERR_PARAM) {
        return BK_EMBED_GPIO_INVALID_ARG;
    }
    return BK_EMBED_GPIO_UNEXPECTED;
}

int bk_embed_gpio_read(uint32_t gpio_id, uint32_t *level)
{
    if (level == 0) {
        return BK_EMBED_GPIO_INVALID_ARG;
    }

    *level = bk_gpio_get_input((gpio_id_t)gpio_id) ? 1u : 0u;
    return BK_EMBED_GPIO_OK;
}

int bk_embed_gpio_write(uint32_t gpio_id, uint32_t level)
{
    if (level != 0) {
        return map_gpio_rc(bk_gpio_set_output_high((gpio_id_t)gpio_id));
    }
    return map_gpio_rc(bk_gpio_set_output_low((gpio_id_t)gpio_id));
}

int bk_embed_gpio_set_direction(uint32_t gpio_id, uint32_t direction)
{
    gpio_dev_unmap((gpio_id_t)gpio_id);
    if (direction == 0) {
        return map_gpio_rc(bk_gpio_enable_output((gpio_id_t)gpio_id));
    }

    int rc = map_gpio_rc(bk_gpio_disable_output((gpio_id_t)gpio_id));
    if (rc != BK_EMBED_GPIO_OK) return rc;
    return map_gpio_rc(bk_gpio_enable_input((gpio_id_t)gpio_id));
}

int bk_embed_gpio_configure_interrupt(uint32_t gpio_id, uint32_t edge)
{
    (void)gpio_id;
    (void)edge;
    return BK_EMBED_GPIO_UNSUPPORTED;
}

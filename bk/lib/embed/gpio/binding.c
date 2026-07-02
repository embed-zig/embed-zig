#include <stdbool.h>
#include <stdint.h>

#include <common/bk_err.h>
#include <driver/gpio.h>
#include <os/os.h>
#include "gpio_driver.h"

#define BK_EMBED_GPIO_OK 0
#define BK_EMBED_GPIO_INVALID_ARG 1
#define BK_EMBED_GPIO_UNSUPPORTED 2
#define BK_EMBED_GPIO_UNEXPECTED 9

#define BK_EMBED_GPIO_EDGE_RISING 0
#define BK_EMBED_GPIO_EDGE_FALLING 1
#define BK_EMBED_GPIO_EDGE_BOTH 2
#define BK_EMBED_GPIO_EDGE_LOW_LEVEL 3
#define BK_EMBED_GPIO_EDGE_HIGH_LEVEL 4

typedef void (*bk_embed_gpio_event_cb)(void *ctx, uint32_t edge, uint32_t level);

typedef struct {
    void *ctx;
    bk_embed_gpio_event_cb cb;
    uint32_t edge;
    uint32_t last_level;
    bool has_last_level;
} bk_embed_gpio_slot_t;

static bk_embed_gpio_slot_t s_slots[GPIO_NUM_MAX];
static beken_queue_t s_queue;
static beken_thread_t s_task;

static int ensure_event_task(void);
static void event_task(beken_thread_arg_t arg);
static void gpio_isr(gpio_id_t gpio_id);
static int map_edge(uint32_t edge, uint32_t level, gpio_int_type_t *type);
static uint32_t event_edge_for_level(bk_embed_gpio_slot_t *slot, uint32_t level);
static void update_next_both_edge(gpio_id_t gpio_id, uint32_t level);

static int map_gpio_rc(bk_err_t rc)
{
    if (rc == BK_OK) {
        return BK_EMBED_GPIO_OK;
    }
    if (rc == BK_ERR_GPIO_CHAN_ID ||
        rc == BK_ERR_GPIO_INVALID_ID ||
        rc == BK_ERR_GPIO_INVALID_INT_TYPE ||
        rc == BK_ERR_PARAM) {
        return BK_EMBED_GPIO_INVALID_ARG;
    }
    return BK_EMBED_GPIO_UNEXPECTED;
}

int bk_embed_gpio_read(uint32_t gpio_id, uint32_t *level)
{
    if (level == NULL || gpio_id >= GPIO_NUM_MAX) {
        return BK_EMBED_GPIO_INVALID_ARG;
    }

    *level = bk_gpio_get_input((gpio_id_t)gpio_id) ? 1u : 0u;
    return BK_EMBED_GPIO_OK;
}

int bk_embed_gpio_write(uint32_t gpio_id, uint32_t level)
{
    if (gpio_id >= GPIO_NUM_MAX) return BK_EMBED_GPIO_INVALID_ARG;

    if (level != 0) {
        return map_gpio_rc(bk_gpio_set_output_high((gpio_id_t)gpio_id));
    }
    return map_gpio_rc(bk_gpio_set_output_low((gpio_id_t)gpio_id));
}

int bk_embed_gpio_set_direction(uint32_t gpio_id, uint32_t direction)
{
    if (gpio_id >= GPIO_NUM_MAX) return BK_EMBED_GPIO_INVALID_ARG;

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
    if (gpio_id >= GPIO_NUM_MAX) return BK_EMBED_GPIO_INVALID_ARG;

    gpio_id_t gpio = (gpio_id_t)gpio_id;
    int rc = ensure_event_task();
    if (rc != BK_EMBED_GPIO_OK) return rc;

    rc = map_gpio_rc(bk_gpio_enable_input(gpio));
    if (rc != BK_EMBED_GPIO_OK) return rc;

    uint32_t level = bk_gpio_get_input(gpio) ? 1u : 0u;
    gpio_int_type_t type;
    rc = map_edge(edge, level, &type);
    if (rc != BK_EMBED_GPIO_OK) return rc;

    s_slots[gpio_id].edge = edge;
    s_slots[gpio_id].last_level = level;
    s_slots[gpio_id].has_last_level = true;

    rc = map_gpio_rc(bk_gpio_disable_interrupt(gpio));
    if (rc != BK_EMBED_GPIO_OK) return rc;
    rc = map_gpio_rc(bk_gpio_register_isr(gpio, gpio_isr));
    if (rc != BK_EMBED_GPIO_OK) return rc;
    rc = map_gpio_rc(bk_gpio_set_interrupt_type(gpio, type));
    if (rc != BK_EMBED_GPIO_OK) return rc;
    rc = map_gpio_rc(bk_gpio_clear_interrupt(gpio));
    if (rc != BK_EMBED_GPIO_OK) return rc;
    return map_gpio_rc(bk_gpio_enable_interrupt(gpio));
}

int bk_embed_gpio_set_callback(uint32_t gpio_id, void *ctx, bk_embed_gpio_event_cb cb)
{
    if (gpio_id >= GPIO_NUM_MAX) return BK_EMBED_GPIO_INVALID_ARG;
    s_slots[gpio_id].ctx = ctx;
    s_slots[gpio_id].cb = cb;
    return BK_EMBED_GPIO_OK;
}

int bk_embed_gpio_clear_callback(uint32_t gpio_id)
{
    if (gpio_id >= GPIO_NUM_MAX) return BK_EMBED_GPIO_INVALID_ARG;

    gpio_id_t gpio = (gpio_id_t)gpio_id;
    (void)bk_gpio_disable_interrupt(gpio);
    (void)bk_gpio_register_isr(gpio, NULL);
    s_slots[gpio_id].ctx = NULL;
    s_slots[gpio_id].cb = NULL;
    return BK_EMBED_GPIO_OK;
}

static int ensure_event_task(void)
{
    if (s_queue == NULL) {
        bk_err_t rc = rtos_init_queue(&s_queue, "bk_gpio_evt", sizeof(uint32_t), 16);
        if (rc != BK_OK) return map_gpio_rc(rc);
    }
    if (s_task == NULL) {
        bk_err_t rc = rtos_create_thread(&s_task, BEKEN_APPLICATION_PRIORITY, "bk_gpio_evt", event_task, 3072, NULL);
        if (rc != BK_OK) return map_gpio_rc(rc);
    }
    return BK_EMBED_GPIO_OK;
}

static void gpio_isr(gpio_id_t gpio_id)
{
    uint32_t pin = (uint32_t)gpio_id;
    if (s_queue != NULL) {
        (void)rtos_push_to_queue(&s_queue, &pin, BEKEN_NO_WAIT);
    }
}

static int map_edge(uint32_t edge, uint32_t level, gpio_int_type_t *type)
{
    if (type == NULL) return BK_EMBED_GPIO_INVALID_ARG;

    switch (edge) {
        case BK_EMBED_GPIO_EDGE_RISING:
            *type = GPIO_INT_TYPE_RISING_EDGE;
            return BK_EMBED_GPIO_OK;
        case BK_EMBED_GPIO_EDGE_FALLING:
            *type = GPIO_INT_TYPE_FALLING_EDGE;
            return BK_EMBED_GPIO_OK;
        case BK_EMBED_GPIO_EDGE_BOTH:
            *type = level ? GPIO_INT_TYPE_FALLING_EDGE : GPIO_INT_TYPE_RISING_EDGE;
            return BK_EMBED_GPIO_OK;
        case BK_EMBED_GPIO_EDGE_LOW_LEVEL:
            *type = GPIO_INT_TYPE_LOW_LEVEL;
            return BK_EMBED_GPIO_OK;
        case BK_EMBED_GPIO_EDGE_HIGH_LEVEL:
            *type = GPIO_INT_TYPE_HIGH_LEVEL;
            return BK_EMBED_GPIO_OK;
        default:
            return BK_EMBED_GPIO_INVALID_ARG;
    }
}

static uint32_t event_edge_for_level(bk_embed_gpio_slot_t *slot, uint32_t level)
{
    if (!slot->has_last_level) {
        return level ? BK_EMBED_GPIO_EDGE_HIGH_LEVEL : BK_EMBED_GPIO_EDGE_LOW_LEVEL;
    }
    if (slot->last_level == 0 && level != 0) return BK_EMBED_GPIO_EDGE_RISING;
    if (slot->last_level != 0 && level == 0) return BK_EMBED_GPIO_EDGE_FALLING;
    return level ? BK_EMBED_GPIO_EDGE_HIGH_LEVEL : BK_EMBED_GPIO_EDGE_LOW_LEVEL;
}

static void update_next_both_edge(gpio_id_t gpio_id, uint32_t level)
{
    gpio_int_type_t next_type = level ? GPIO_INT_TYPE_FALLING_EDGE : GPIO_INT_TYPE_RISING_EDGE;
    (void)bk_gpio_set_interrupt_type(gpio_id, next_type);
    (void)bk_gpio_clear_interrupt(gpio_id);
    (void)bk_gpio_enable_interrupt(gpio_id);
}

static void event_task(beken_thread_arg_t arg)
{
    (void)arg;
    while (true) {
        uint32_t pin = 0;
        bk_err_t rc = rtos_pop_from_queue(&s_queue, &pin, BEKEN_WAIT_FOREVER);
        if (rc != BK_OK || pin >= GPIO_NUM_MAX) continue;

        gpio_id_t gpio = (gpio_id_t)pin;
        bk_embed_gpio_slot_t *slot = &s_slots[pin];
        uint32_t level = bk_gpio_get_input(gpio) ? 1u : 0u;
        uint32_t edge = event_edge_for_level(slot, level);
        slot->last_level = level;
        slot->has_last_level = true;

        if (slot->edge == BK_EMBED_GPIO_EDGE_BOTH) {
            update_next_both_edge(gpio, level);
        }

        if (slot->cb != NULL) {
            slot->cb(slot->ctx, edge, level);
        }
    }
}

#include <stdbool.h>
#include <stdint.h>

#include "driver/gpio.h"
#include "esp_err.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"

#define ESP_EMBED_GPIO_EDGE_RISING 0
#define ESP_EMBED_GPIO_EDGE_FALLING 1
#define ESP_EMBED_GPIO_EDGE_BOTH 2
#define ESP_EMBED_GPIO_EDGE_LOW_LEVEL 3
#define ESP_EMBED_GPIO_EDGE_HIGH_LEVEL 4

typedef void (*esp_embed_gpio_event_cb)(void *ctx, uint32_t edge, uint32_t level);

typedef struct {
    void *ctx;
    esp_embed_gpio_event_cb cb;
    uint32_t edge;
    uint32_t last_level;
    bool has_last_level;
} esp_embed_gpio_slot_t;

static esp_embed_gpio_slot_t s_slots[GPIO_NUM_MAX];
static QueueHandle_t s_queue;
static TaskHandle_t s_task;
static bool s_isr_service_installed;

static esp_err_t ensure_event_task(void);
static void event_task(void *arg);
static void IRAM_ATTR gpio_isr(void *arg);

int esp_embed_gpio_read(int pin, uint32_t *level)
{
    if (level == NULL || pin < 0 || pin >= GPIO_NUM_MAX) return ESP_ERR_INVALID_ARG;
    *level = gpio_get_level((gpio_num_t)pin) ? 1u : 0u;
    return ESP_OK;
}
int esp_embed_gpio_write(int pin, uint32_t level)
{
    if (pin < 0 || pin >= GPIO_NUM_MAX) return ESP_ERR_INVALID_ARG;
    return gpio_set_level((gpio_num_t)pin, level ? 1 : 0);
}

int esp_embed_gpio_set_direction(int pin, uint32_t direction)
{
    if (pin < 0 || pin >= GPIO_NUM_MAX) return ESP_ERR_INVALID_ARG;
    return gpio_set_direction((gpio_num_t)pin, direction == 0 ? GPIO_MODE_OUTPUT : GPIO_MODE_INPUT);
}

int esp_embed_gpio_configure_interrupt(int pin, uint32_t edge)
{
    if (pin < 0 || pin >= GPIO_NUM_MAX) return ESP_ERR_INVALID_ARG;

    gpio_int_type_t intr_type;
    switch (edge) {
        case ESP_EMBED_GPIO_EDGE_RISING:
            intr_type = GPIO_INTR_POSEDGE;
            break;
        case ESP_EMBED_GPIO_EDGE_FALLING:
            intr_type = GPIO_INTR_NEGEDGE;
            break;
        case ESP_EMBED_GPIO_EDGE_BOTH:
            intr_type = GPIO_INTR_ANYEDGE;
            break;
        case ESP_EMBED_GPIO_EDGE_LOW_LEVEL:
            intr_type = GPIO_INTR_LOW_LEVEL;
            break;
        case ESP_EMBED_GPIO_EDGE_HIGH_LEVEL:
            intr_type = GPIO_INTR_HIGH_LEVEL;
            break;
        default:
            return ESP_ERR_INVALID_ARG;
    }

    esp_err_t rc = ensure_event_task();
    if (rc != ESP_OK) return rc;

    if (!s_isr_service_installed) {
        rc = gpio_install_isr_service(0);
        if (rc != ESP_OK && rc != ESP_ERR_INVALID_STATE) return rc;
        s_isr_service_installed = true;
    }

    gpio_num_t gpio = (gpio_num_t)pin;
    s_slots[pin].edge = edge;
    s_slots[pin].last_level = gpio_get_level(gpio) ? 1u : 0u;
    s_slots[pin].has_last_level = true;

    rc = gpio_set_intr_type(gpio, intr_type);
    if (rc != ESP_OK) return rc;
    rc = gpio_isr_handler_add(gpio, gpio_isr, (void *)(intptr_t)pin);
    if (rc != ESP_OK && rc != ESP_ERR_INVALID_STATE) return rc;
    return gpio_intr_enable(gpio);
}

int esp_embed_gpio_set_callback(int pin, void *ctx, esp_embed_gpio_event_cb cb)
{
    if (pin < 0 || pin >= GPIO_NUM_MAX) return ESP_ERR_INVALID_ARG;
    s_slots[pin].ctx = ctx;
    s_slots[pin].cb = cb;
    return ESP_OK;
}

int esp_embed_gpio_clear_callback(int pin)
{
    if (pin < 0 || pin >= GPIO_NUM_MAX) return ESP_ERR_INVALID_ARG;
    gpio_intr_disable((gpio_num_t)pin);
    gpio_isr_handler_remove((gpio_num_t)pin);
    s_slots[pin].ctx = NULL;
    s_slots[pin].cb = NULL;
    return ESP_OK;
}

static esp_err_t ensure_event_task(void)
{
    if (s_queue == NULL) {
        s_queue = xQueueCreate(16, sizeof(uint32_t));
        if (s_queue == NULL) return ESP_ERR_NO_MEM;
    }
    if (s_task == NULL) {
        BaseType_t ok = xTaskCreate(event_task, "esp_gpio_evt", 3072, NULL, 10, &s_task);
        if (ok != pdPASS) return ESP_ERR_NO_MEM;
    }
    return ESP_OK;
}

static void IRAM_ATTR gpio_isr(void *arg)
{
    uint32_t pin = (uint32_t)(uintptr_t)arg;
    BaseType_t task_woken = pdFALSE;
    if (s_queue != NULL) {
        xQueueSendFromISR(s_queue, &pin, &task_woken);
    }
    if (task_woken == pdTRUE) {
        portYIELD_FROM_ISR();
    }
}

static uint32_t event_edge_for_level(esp_embed_gpio_slot_t *slot, uint32_t level)
{
    if (!slot->has_last_level) {
        return level ? ESP_EMBED_GPIO_EDGE_HIGH_LEVEL : ESP_EMBED_GPIO_EDGE_LOW_LEVEL;
    }
    if (slot->last_level == 0 && level != 0) return ESP_EMBED_GPIO_EDGE_RISING;
    if (slot->last_level != 0 && level == 0) return ESP_EMBED_GPIO_EDGE_FALLING;
    return level ? ESP_EMBED_GPIO_EDGE_HIGH_LEVEL : ESP_EMBED_GPIO_EDGE_LOW_LEVEL;
}

static void event_task(void *arg)
{
    (void)arg;
    while (true) {
        uint32_t pin = 0;
        if (xQueueReceive(s_queue, &pin, portMAX_DELAY) != pdTRUE) continue;
        if (pin >= GPIO_NUM_MAX) continue;

        esp_embed_gpio_slot_t *slot = &s_slots[pin];
        uint32_t level = gpio_get_level((gpio_num_t)pin) ? 1u : 0u;
        uint32_t edge = event_edge_for_level(slot, level);
        slot->last_level = level;
        slot->has_last_level = true;

        if (slot->cb != NULL) {
            slot->cb(slot->ctx, edge, level);
        }
    }
}

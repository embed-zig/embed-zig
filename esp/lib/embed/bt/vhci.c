#include "esp_bt.h"
#include "esp_err.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#define ESP_EMBED_BT_PACKET_MAX 1024
#define ESP_EMBED_BT_RX_QUEUE_LEN 16

typedef struct {
    uint16_t len;
    uint8_t data[ESP_EMBED_BT_PACKET_MAX];
} esp_embed_bt_packet_t;

static QueueHandle_t s_rx_queue;
static SemaphoreHandle_t s_send_ready;
static bool s_initialized;

static void esp_embed_bt_notify_host_send_available(void) {
    if (s_send_ready != NULL) {
        xSemaphoreGive(s_send_ready);
    }
}

static int esp_embed_bt_notify_host_recv(uint8_t *data, uint16_t len) {
    if (s_rx_queue == NULL || data == NULL || len > ESP_EMBED_BT_PACKET_MAX) {
        return 0;
    }
    esp_embed_bt_packet_t packet = {0};
    packet.len = len;
    memcpy(packet.data, data, len);
    (void)xQueueSend(s_rx_queue, &packet, 0);
    return 0;
}

int esp_embed_bt_vhci_init(void) {
    if (s_initialized) return ESP_OK;

    s_rx_queue = xQueueCreate(ESP_EMBED_BT_RX_QUEUE_LEN, sizeof(esp_embed_bt_packet_t));
    s_send_ready = xSemaphoreCreateBinary();
    if (s_rx_queue == NULL || s_send_ready == NULL) return ESP_FAIL;

    esp_bt_controller_config_t bt_cfg = BT_CONTROLLER_INIT_CONFIG_DEFAULT();
    esp_err_t err = esp_bt_controller_init(&bt_cfg);
    if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) return err;

    err = esp_bt_controller_enable(ESP_BT_MODE_BLE);
    if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) return err;

    static const esp_vhci_host_callback_t cb = {
        .notify_host_send_available = esp_embed_bt_notify_host_send_available,
        .notify_host_recv = esp_embed_bt_notify_host_recv,
    };
    err = esp_vhci_host_register_callback(&cb);
    if (err != ESP_OK) return err;

    xSemaphoreGive(s_send_ready);
    s_initialized = true;
    return ESP_OK;
}

int esp_embed_bt_vhci_send(const uint8_t *data, size_t len, uint32_t timeout_ms) {
    if (!s_initialized || data == NULL || len > UINT16_MAX) return ESP_FAIL;
    const TickType_t deadline = timeout_ms == UINT32_MAX ? portMAX_DELAY : pdMS_TO_TICKS(timeout_ms);
    while (!esp_vhci_host_check_send_available()) {
        if (xSemaphoreTake(s_send_ready, deadline) != pdTRUE) return ESP_ERR_TIMEOUT;
    }
    esp_vhci_host_send_packet((uint8_t *)data, (uint16_t)len);
    return ESP_OK;
}

int esp_embed_bt_vhci_recv(uint8_t *out, size_t cap, size_t *out_len, uint32_t timeout_ms) {
    if (!s_initialized || out == NULL || out_len == NULL) return ESP_FAIL;
    esp_embed_bt_packet_t packet = {0};
    const TickType_t ticks = timeout_ms == UINT32_MAX ? portMAX_DELAY : pdMS_TO_TICKS(timeout_ms);
    if (xQueueReceive(s_rx_queue, &packet, ticks) != pdTRUE) return ESP_ERR_TIMEOUT;
    if (packet.len > cap) return ESP_FAIL;
    memcpy(out, packet.data, packet.len);
    *out_len = packet.len;
    return ESP_OK;
}

#include "esp_err.h"
#include "esp_hosted.h"
#include "esp_hosted_os_abstraction.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#define ESP_EMBED_BT_PACKET_MAX 1024
#define ESP_EMBED_BT_RX_QUEUE_LEN 16
#define ESP_EMBED_BT_HOSTED_HCI_IF 4
#define ESP_EMBED_BT_HOSTED_NO_ZEROCOPY 0

extern int esp_hosted_tx(uint8_t iface_type, uint8_t iface_num, uint8_t *payload_buf, uint16_t payload_len, uint8_t buff_zerocopy, uint8_t *buffer_to_free, void (*free_buf_func)(void *ptr), uint8_t flags);

typedef struct {
    uint16_t len;
    uint8_t data[ESP_EMBED_BT_PACKET_MAX];
} esp_embed_bt_packet_t;

static QueueHandle_t s_rx_queue;
static bool s_initialized;

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

int hci_rx_handler(uint8_t *data, size_t len) {
    if (len > UINT16_MAX) return ESP_FAIL;
    esp_embed_bt_notify_host_recv(data, (uint16_t)len);
    return ESP_OK;
}

int esp_embed_bt_remote_hci_init(void) {
    if (s_initialized) return ESP_OK;

    s_rx_queue = xQueueCreate(ESP_EMBED_BT_RX_QUEUE_LEN, sizeof(esp_embed_bt_packet_t));
    if (s_rx_queue == NULL) return ESP_FAIL;

    esp_err_t err = esp_hosted_init();
    if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) return err;

    err = esp_hosted_connect_to_slave();
    if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) return err;

    err = esp_hosted_bt_controller_init();
    if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) return err;

    err = esp_hosted_bt_controller_enable();
    if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) return err;

    s_initialized = true;
    return ESP_OK;
}

int esp_embed_bt_remote_hci_send(const uint8_t *data, size_t len, uint32_t timeout_ms) {
    if (!s_initialized || data == NULL || len > UINT16_MAX) return ESP_FAIL;
    (void)timeout_ms;
    uint8_t *copy = (uint8_t *)g_h.funcs->_h_malloc(len);
    if (copy == NULL) return ESP_FAIL;
    memcpy(copy, data, len);
    return esp_hosted_tx(ESP_EMBED_BT_HOSTED_HCI_IF, 0, copy, (uint16_t)len, ESP_EMBED_BT_HOSTED_NO_ZEROCOPY, copy, g_h.funcs->_h_free, 0);
}

int esp_embed_bt_remote_hci_recv(uint8_t *out, size_t cap, size_t *out_len, uint32_t timeout_ms) {
    if (!s_initialized || out == NULL || out_len == NULL) return ESP_FAIL;
    esp_embed_bt_packet_t packet = {0};
    const TickType_t ticks = timeout_ms == UINT32_MAX ? portMAX_DELAY : pdMS_TO_TICKS(timeout_ms);
    if (xQueueReceive(s_rx_queue, &packet, ticks) != pdTRUE) return ESP_ERR_TIMEOUT;
    if (packet.len > cap) return ESP_FAIL;
    memcpy(out, packet.data, packet.len);
    *out_len = packet.len;
    return ESP_OK;
}

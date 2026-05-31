#include <stddef.h>
#include <stdint.h>

#include "esp_err.h"
#include "esp_lcd_panel_io.h"

int esp_embed_display_native_dbi_write_cmd(void *panel_io, int command, const uint8_t *data, size_t len)
{
    if (panel_io == NULL) return ESP_ERR_INVALID_STATE;
    if (data == NULL && len != 0) return ESP_ERR_INVALID_ARG;
    return esp_lcd_panel_io_tx_param((esp_lcd_panel_io_handle_t)panel_io, command, data, len);
}

int esp_embed_display_native_dbi_write_data(void *panel_io, const uint8_t *data, size_t len)
{
    if (panel_io == NULL) return ESP_ERR_INVALID_STATE;
    if (data == NULL && len != 0) return ESP_ERR_INVALID_ARG;
    if (len == 0) return ESP_OK;

    esp_lcd_panel_io_handle_t io = (esp_lcd_panel_io_handle_t)panel_io;
    esp_err_t err = esp_lcd_panel_io_tx_color(io, -1, data, len);
    if (err != ESP_OK) return err;

    // tx_color is queued by the ESP-IDF SPI LCD backend. Drain the queue before
    // returning so callers can safely reuse or rewrite their DMA buffer.
    return esp_lcd_panel_io_tx_param(io, -1, NULL, 0);
}

int esp_embed_display_native_dbi_write_cmd_data(void *panel_io, int command, const uint8_t *data, size_t len)
{
    if (panel_io == NULL) return ESP_ERR_INVALID_STATE;
    if (data == NULL && len != 0) return ESP_ERR_INVALID_ARG;

    esp_lcd_panel_io_handle_t io = (esp_lcd_panel_io_handle_t)panel_io;
    esp_err_t err = esp_lcd_panel_io_tx_color(io, command, data, len);
    if (err != ESP_OK) return err;

    return esp_lcd_panel_io_tx_param(io, -1, NULL, 0);
}

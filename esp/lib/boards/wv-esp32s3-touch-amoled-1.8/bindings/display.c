#include "wv_board.h"

#include "driver/spi_master.h"
#include "esp_check.h"
#include "esp_err.h"
#include "esp_lcd_panel_io.h"
#include "esp_lcd_sh8601.h"
#include "esp_log.h"

#define LCD_HOST SPI2_HOST
#define LCD_WIDTH 368
#define LCD_HEIGHT 448
#define LCD_CS_GPIO GPIO_NUM_12
#define LCD_PCLK_GPIO GPIO_NUM_11
#define LCD_DATA0_GPIO GPIO_NUM_4
#define LCD_DATA1_GPIO GPIO_NUM_5
#define LCD_DATA2_GPIO GPIO_NUM_6
#define LCD_DATA3_GPIO GPIO_NUM_7
#define LCD_RST_GPIO GPIO_NUM_NC
#define LCD_BITS_PER_PIXEL 16
#define LCD_DRAW_ROWS 8

static const char *TAG = "wv_display";
static esp_lcd_panel_io_handle_t panel_io;

int wv_display_native_init(void)
{
    if (panel_io != NULL) return ESP_OK;

    ESP_LOGI(TAG, "init SH8601 panel IO");

    const spi_bus_config_t buscfg = SH8601_PANEL_BUS_QSPI_CONFIG(
        LCD_PCLK_GPIO,
        LCD_DATA0_GPIO,
        LCD_DATA1_GPIO,
        LCD_DATA2_GPIO,
        LCD_DATA3_GPIO,
        LCD_WIDTH * LCD_DRAW_ROWS * LCD_BITS_PER_PIXEL / 8);
    ESP_RETURN_ON_ERROR(spi_bus_initialize(LCD_HOST, &buscfg, SPI_DMA_CH_AUTO), TAG, "spi bus");

    const esp_lcd_panel_io_spi_config_t io_config = SH8601_PANEL_IO_QSPI_CONFIG(
        LCD_CS_GPIO,
        NULL,
        NULL);
    return esp_lcd_new_panel_io_spi((esp_lcd_spi_bus_handle_t)LCD_HOST, &io_config, &panel_io);
}

void *wv_display_native_panel_io(void)
{
    return panel_io;
}

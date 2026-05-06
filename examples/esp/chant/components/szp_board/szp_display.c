#include "szp_board.h"

#include "driver/gpio.h"
#include "driver/spi_master.h"
#include "esp_check.h"
#include "esp_err.h"
#include "esp_lcd_panel_io.h"
#include "esp_lcd_panel_ops.h"
#include "esp_lcd_panel_vendor.h"

#define LCD_HOST SPI3_HOST
#define LCD_WIDTH 320
#define LCD_HEIGHT 240
#define LCD_MOSI_GPIO 40
#define LCD_CLK_GPIO 41
#define LCD_DC_GPIO 39
#define LCD_BACKLIGHT_GPIO 42

static const char *TAG = "szp_display";
static esp_lcd_panel_handle_t panel;
static uint16_t line_buffer[LCD_WIDTH * 20];

int szp_pca9557_set_lcd_cs(bool high);

static uint16_t rgb565(uint8_t r, uint8_t g, uint8_t b)
{
    return (uint16_t)(((r & 0xf8) << 8) | ((g & 0xfc) << 3) | (b >> 3));
}

int szp_display_init(void)
{
    if (panel != NULL) return ESP_OK;

    gpio_config_t backlight_cfg = {
        .pin_bit_mask = 1ULL << LCD_BACKLIGHT_GPIO,
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    ESP_RETURN_ON_ERROR(gpio_config(&backlight_cfg), TAG, "backlight gpio");
    gpio_set_level(LCD_BACKLIGHT_GPIO, 1);

    spi_bus_config_t bus_cfg = {
        .mosi_io_num = LCD_MOSI_GPIO,
        .miso_io_num = GPIO_NUM_NC,
        .sclk_io_num = LCD_CLK_GPIO,
        .quadwp_io_num = GPIO_NUM_NC,
        .quadhd_io_num = GPIO_NUM_NC,
        .max_transfer_sz = sizeof(line_buffer),
    };
    ESP_RETURN_ON_ERROR(spi_bus_initialize(LCD_HOST, &bus_cfg, SPI_DMA_CH_AUTO), TAG, "spi bus");

    ESP_RETURN_ON_ERROR(szp_pca9557_set_lcd_cs(false), TAG, "lcd cs low");
    esp_lcd_panel_io_handle_t io = NULL;
    esp_lcd_panel_io_spi_config_t io_cfg = {
        .dc_gpio_num = LCD_DC_GPIO,
        .cs_gpio_num = GPIO_NUM_NC,
        .pclk_hz = 40 * 1000 * 1000,
        .lcd_cmd_bits = 8,
        .lcd_param_bits = 8,
        .spi_mode = 0,
        .trans_queue_depth = 10,
    };
    ESP_RETURN_ON_ERROR(esp_lcd_new_panel_io_spi((esp_lcd_spi_bus_handle_t)LCD_HOST, &io_cfg, &io), TAG, "lcd io");

    esp_lcd_panel_dev_config_t panel_cfg = {
        .reset_gpio_num = GPIO_NUM_NC,
        .rgb_ele_order = LCD_RGB_ELEMENT_ORDER_RGB,
        .bits_per_pixel = 16,
    };
    ESP_RETURN_ON_ERROR(esp_lcd_new_panel_st7789(io, &panel_cfg, &panel), TAG, "st7789 panel");
    ESP_RETURN_ON_ERROR(esp_lcd_panel_reset(panel), TAG, "panel reset");
    ESP_RETURN_ON_ERROR(esp_lcd_panel_init(panel), TAG, "panel init");
    ESP_RETURN_ON_ERROR(esp_lcd_panel_invert_color(panel, true), TAG, "panel invert");
    ESP_RETURN_ON_ERROR(esp_lcd_panel_swap_xy(panel, true), TAG, "panel swap xy");
    ESP_RETURN_ON_ERROR(esp_lcd_panel_mirror(panel, true, false), TAG, "panel mirror");
    ESP_RETURN_ON_ERROR(esp_lcd_panel_disp_on_off(panel, true), TAG, "panel on");
    return szp_display_show_track(SZP_TRACK_TWINKLE);
}

int szp_display_show_track(szp_track_t track)
{
    ESP_RETURN_ON_ERROR(szp_display_init(), TAG, "display init");

    uint16_t color = rgb565(20, 20, 80);
    switch (track) {
        case SZP_TRACK_TWINKLE:
            color = rgb565(20, 20, 100);
            break;
        case SZP_TRACK_HAPPY_BIRTHDAY:
            color = rgb565(90, 30, 20);
            break;
        case SZP_TRACK_DOLL_BEAR:
            color = rgb565(20, 90, 45);
            break;
        default:
            break;
    }

    for (size_t i = 0; i < sizeof(line_buffer) / sizeof(line_buffer[0]); i += 1) {
        line_buffer[i] = color;
    }
    for (int y = 0; y < LCD_HEIGHT; y += 20) {
        const int y2 = (y + 20) > LCD_HEIGHT ? LCD_HEIGHT : (y + 20);
        ESP_RETURN_ON_ERROR(esp_lcd_panel_draw_bitmap(panel, 0, y, LCD_WIDTH, y2, line_buffer), TAG, "draw");
    }
    return ESP_OK;
}

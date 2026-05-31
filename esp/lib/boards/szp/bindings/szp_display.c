#include "szp_board.h"

#include "driver/ledc.h"
#include "driver/spi_master.h"
#include "esp_check.h"
#include "esp_err.h"
#include "esp_lcd_panel_io.h"
#include "esp_log.h"

#define LCD_HOST SPI3_HOST
#define LCD_WIDTH 320
#define LCD_HEIGHT 240
#define LCD_MOSI_GPIO 40
#define LCD_CLK_GPIO 41
#define LCD_DC_GPIO 39
#define LCD_BACKLIGHT_GPIO 42
#define LCD_LEDC_CHANNEL LEDC_CHANNEL_0
#define LCD_LEDC_TIMER LEDC_TIMER_1
#define LCD_DRAW_ROWS 10

static const char *TAG = "szp_display";
static esp_lcd_panel_io_handle_t panel_io;

int szp_pca9557_set_lcd_cs(bool high);

static esp_err_t backlight_init(void)
{
    const ledc_timer_config_t timer = {
        .speed_mode = LEDC_LOW_SPEED_MODE,
        .duty_resolution = LEDC_TIMER_10_BIT,
        .timer_num = LCD_LEDC_TIMER,
        .freq_hz = 5000,
        .clk_cfg = LEDC_AUTO_CLK,
    };
    ESP_RETURN_ON_ERROR(ledc_timer_config(&timer), TAG, "backlight timer");

    const ledc_channel_config_t channel = {
        .gpio_num = LCD_BACKLIGHT_GPIO,
        .speed_mode = LEDC_LOW_SPEED_MODE,
        .channel = LCD_LEDC_CHANNEL,
        .intr_type = LEDC_INTR_DISABLE,
        .timer_sel = LCD_LEDC_TIMER,
        .duty = 0,
        .hpoint = 0,
        .flags.output_invert = true,
    };
    return ledc_channel_config(&channel);
}

static esp_err_t backlight_on(void)
{
    ESP_RETURN_ON_ERROR(ledc_set_duty(LEDC_LOW_SPEED_MODE, LCD_LEDC_CHANNEL, 1023), TAG, "backlight duty");
    return ledc_update_duty(LEDC_LOW_SPEED_MODE, LCD_LEDC_CHANNEL);
}

static esp_err_t backlight_set_brightness(uint8_t brightness)
{
    uint32_t duty = ((uint32_t)brightness * 1023U) / 255U;
    ESP_RETURN_ON_ERROR(ledc_set_duty(LEDC_LOW_SPEED_MODE, LCD_LEDC_CHANNEL, duty), TAG, "backlight duty");
    return ledc_update_duty(LEDC_LOW_SPEED_MODE, LCD_LEDC_CHANNEL);
}

int szp_display_native_init(void)
{
    if (panel_io != NULL) return ESP_OK;

    ESP_LOGI(TAG, "init display");
    ESP_RETURN_ON_ERROR(backlight_init(), TAG, "backlight init");

    spi_bus_config_t bus_cfg = {
        .mosi_io_num = LCD_MOSI_GPIO,
        .miso_io_num = GPIO_NUM_NC,
        .sclk_io_num = LCD_CLK_GPIO,
        .quadwp_io_num = GPIO_NUM_NC,
        .quadhd_io_num = GPIO_NUM_NC,
        .max_transfer_sz = LCD_WIDTH * LCD_DRAW_ROWS * sizeof(uint16_t),
    };
    ESP_RETURN_ON_ERROR(spi_bus_initialize(LCD_HOST, &bus_cfg, SPI_DMA_CH_AUTO), TAG, "spi bus");

    esp_lcd_panel_io_spi_config_t io_cfg = {
        .dc_gpio_num = LCD_DC_GPIO,
        .cs_gpio_num = GPIO_NUM_NC,
        .pclk_hz = 80 * 1000 * 1000,
        .lcd_cmd_bits = 8,
        .lcd_param_bits = 8,
        .spi_mode = 2,
        .trans_queue_depth = 10,
    };
    ESP_RETURN_ON_ERROR(esp_lcd_new_panel_io_spi((esp_lcd_spi_bus_handle_t)LCD_HOST, &io_cfg, &panel_io), TAG, "lcd io");

    ESP_RETURN_ON_ERROR(szp_pca9557_set_lcd_cs(true), TAG, "lcd cs high");
    return backlight_on();
}

void *szp_display_native_panel_io(void)
{
    return panel_io;
}

int szp_display_native_set_brightness(uint8_t brightness)
{
    if (panel_io == NULL) return ESP_ERR_INVALID_STATE;
    return backlight_set_brightness(brightness);
}

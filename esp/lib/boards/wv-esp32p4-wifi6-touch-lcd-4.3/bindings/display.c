#include "wv_p4_board.h"

#include "driver/ledc.h"
#include "driver/gpio.h"
#include "esp_check.h"
#include "esp_err.h"
#include "esp_lcd_mipi_dsi.h"
#include "esp_lcd_panel_ops.h"
#include "esp_ldo_regulator.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#define LCD_WIDTH 480
#define LCD_HEIGHT 800
#define LCD_BACKLIGHT_GPIO GPIO_NUM_26
#define LCD_RESET_GPIO GPIO_NUM_27
#define LCD_BITS_PER_PIXEL 16
#define LCD_DPI_BUFFER_COUNT 3
#define LCD_DSI_BUS_ID 0
#define LCD_DSI_LANE_COUNT 2
#define LCD_DSI_LANE_BITRATE_MBPS 500
#define LCD_DSI_PHY_PWR_LDO_CHAN 3
#define LCD_DSI_PHY_PWR_LDO_VOLTAGE_MV 2500
#define LCD_LEDC_TIMER LEDC_TIMER_1
#define LCD_LEDC_CHANNEL LEDC_CHANNEL_1
#define LCD_LEDC_DUTY_MAX 1023

static const char *TAG = "wv_p4_display";
static esp_lcd_dsi_bus_handle_t dsi_bus;
static esp_lcd_panel_io_handle_t io_handle;
static esp_lcd_panel_handle_t panel_handle;
static esp_ldo_channel_handle_t phy_pwr_chan;
static uint8_t brightness = 100;

static esp_err_t init_backlight(void)
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
        .flags = {.output_invert = 1},
    };
    return ledc_channel_config(&channel);
}

static esp_err_t set_backlight(uint8_t value)
{
    brightness = value;
    const uint32_t duty = ((uint32_t)LCD_LEDC_DUTY_MAX * value) / 255;
    ESP_RETURN_ON_ERROR(ledc_set_duty(LEDC_LOW_SPEED_MODE, LCD_LEDC_CHANNEL, duty), TAG, "backlight duty");
    return ledc_update_duty(LEDC_LOW_SPEED_MODE, LCD_LEDC_CHANNEL);
}

static esp_err_t enable_dsi_phy_power(void)
{
    if (phy_pwr_chan != NULL) return ESP_OK;

    const esp_ldo_channel_config_t ldo_cfg = {
        .chan_id = LCD_DSI_PHY_PWR_LDO_CHAN,
        .voltage_mv = LCD_DSI_PHY_PWR_LDO_VOLTAGE_MV,
    };
    ESP_RETURN_ON_ERROR(esp_ldo_acquire_channel(&ldo_cfg, &phy_pwr_chan), TAG, "DSI PHY power");
    ESP_LOGI(TAG, "MIPI DSI PHY powered on");
    return ESP_OK;
}

int wv_p4_board_init(void)
{
    return ESP_OK;
}

static esp_err_t init_reset_gpio(void)
{
    const gpio_config_t config = {
        .pin_bit_mask = 1ULL << LCD_RESET_GPIO,
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    return gpio_config(&config);
}

int wv_p4_display_native_init(void)
{
    if (panel_handle != NULL) return ESP_OK;

    ESP_LOGI(TAG, "init MIPI DSI display transport");
    ESP_RETURN_ON_ERROR(init_backlight(), TAG, "backlight init");
    ESP_RETURN_ON_ERROR(init_reset_gpio(), TAG, "reset gpio");
    ESP_RETURN_ON_ERROR(enable_dsi_phy_power(), TAG, "DSI PHY power");

    const esp_lcd_dsi_bus_config_t bus_config = {
        .bus_id = LCD_DSI_BUS_ID,
        .num_data_lanes = LCD_DSI_LANE_COUNT,
        .phy_clk_src = MIPI_DSI_PHY_CLK_SRC_DEFAULT,
        .lane_bit_rate_mbps = LCD_DSI_LANE_BITRATE_MBPS,
    };
    ESP_RETURN_ON_ERROR(esp_lcd_new_dsi_bus(&bus_config, &dsi_bus), TAG, "DSI bus");

    const esp_lcd_dbi_io_config_t dbi_config = {
        .virtual_channel = 0,
        .lcd_cmd_bits = 8,
        .lcd_param_bits = 8,
    };
    ESP_RETURN_ON_ERROR(esp_lcd_new_panel_io_dbi(dsi_bus, &dbi_config, &io_handle), TAG, "panel IO");

    esp_lcd_dpi_panel_config_t dpi_config = {
        .dpi_clk_src = MIPI_DSI_DPI_CLK_SRC_DEFAULT,
        .dpi_clock_freq_mhz = 30,
        .virtual_channel = 0,
        .in_color_format = LCD_COLOR_FMT_RGB565,
        .out_color_format = LCD_COLOR_FMT_RGB565,
        .num_fbs = LCD_DPI_BUFFER_COUNT,
        .video_timing = {
            .h_size = LCD_WIDTH,
            .v_size = LCD_HEIGHT,
            .hsync_back_porch = 42,
            .hsync_pulse_width = 12,
            .hsync_front_porch = 42,
            .vsync_back_porch = 2,
            .vsync_pulse_width = 8,
            .vsync_front_porch = 60,
        },
    };
    ESP_RETURN_ON_ERROR(esp_lcd_new_panel_dpi(dsi_bus, &dpi_config, &panel_handle), TAG, "DPI panel");
    ESP_RETURN_ON_ERROR(esp_lcd_dpi_panel_enable_dma2d(panel_handle), TAG, "DMA2D");
    return ESP_OK;
}

void *wv_p4_display_native_panel_io(void)
{
    return io_handle;
}

int wv_p4_display_native_reset_panel(void)
{
    if (io_handle == NULL) return ESP_ERR_INVALID_STATE;
    ESP_RETURN_ON_ERROR(gpio_set_level(LCD_RESET_GPIO, 0), TAG, "reset low");
    vTaskDelay(pdMS_TO_TICKS(10));
    ESP_RETURN_ON_ERROR(gpio_set_level(LCD_RESET_GPIO, 1), TAG, "reset high");
    vTaskDelay(pdMS_TO_TICKS(10));
    return ESP_OK;
}

int wv_p4_display_native_start_panel(void)
{
    if (panel_handle == NULL) return ESP_ERR_INVALID_STATE;
    ESP_RETURN_ON_ERROR(esp_lcd_panel_init(panel_handle), TAG, "DPI panel init");
    ESP_RETURN_ON_ERROR(set_backlight(255), TAG, "backlight on");
    ESP_LOGI(TAG, "display initialized");
    return ESP_OK;
}

int wv_p4_display_native_set_brightness(uint8_t value)
{
    if (panel_handle == NULL) return ESP_ERR_INVALID_STATE;
    return set_backlight(value);
}

int wv_p4_display_native_flush_rgb565(uint16_t x, uint16_t y, uint16_t w, uint16_t h, const uint16_t *pixels, size_t len)
{
    if (panel_handle == NULL || pixels == NULL) return ESP_ERR_INVALID_STATE;
    if ((size_t)w * (size_t)h > len) return ESP_ERR_INVALID_SIZE;
    if ((uint32_t)x + w > LCD_WIDTH || (uint32_t)y + h > LCD_HEIGHT) return ESP_ERR_INVALID_ARG;

    return esp_lcd_panel_draw_bitmap(panel_handle, x, y, x + w, y + h, pixels);
}

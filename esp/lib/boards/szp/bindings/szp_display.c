#include "szp_board.h"

#include "driver/ledc.h"
#include "driver/spi_master.h"
#include "esp_check.h"
#include "esp_err.h"
#include "esp_lcd_panel_io.h"
#include "esp_lcd_panel_ops.h"
#include "esp_lcd_panel_vendor.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"

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
#define LCD_DRAW_SLOW_US 20000
#define LCD_DRAW_WAIT_TIMEOUT_MS 1000

static const char *TAG = "szp_display";
static esp_lcd_panel_handle_t panel;
static SemaphoreHandle_t color_done_sem;
static uint8_t backlight_brightness = 255;
static uint32_t draw_seq;

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

static bool color_transfer_done(esp_lcd_panel_io_handle_t io, esp_lcd_panel_io_event_data_t *edata, void *user_ctx)
{
    (void)io;
    (void)edata;
    SemaphoreHandle_t sem = (SemaphoreHandle_t)user_ctx;
    if (sem == NULL) return false;

    BaseType_t high_task_woken = pdFALSE;
    xSemaphoreGiveFromISR(sem, &high_task_woken);
    return high_task_woken == pdTRUE;
}

int szp_display_native_init(void)
{
    if (panel != NULL) return ESP_OK;

    ESP_LOGI(TAG, "init display");
    ESP_RETURN_ON_ERROR(backlight_init(), TAG, "backlight init");

    color_done_sem = xSemaphoreCreateBinary();
    ESP_RETURN_ON_FALSE(color_done_sem != NULL, ESP_ERR_NO_MEM, TAG, "color semaphore");

    spi_bus_config_t bus_cfg = {
        .mosi_io_num = LCD_MOSI_GPIO,
        .miso_io_num = GPIO_NUM_NC,
        .sclk_io_num = LCD_CLK_GPIO,
        .quadwp_io_num = GPIO_NUM_NC,
        .quadhd_io_num = GPIO_NUM_NC,
        .max_transfer_sz = LCD_WIDTH * LCD_DRAW_ROWS * sizeof(uint16_t),
    };
    ESP_RETURN_ON_ERROR(spi_bus_initialize(LCD_HOST, &bus_cfg, SPI_DMA_CH_AUTO), TAG, "spi bus");

    esp_lcd_panel_io_handle_t io = NULL;
    esp_lcd_panel_io_spi_config_t io_cfg = {
        .dc_gpio_num = LCD_DC_GPIO,
        .cs_gpio_num = GPIO_NUM_NC,
        .pclk_hz = 80 * 1000 * 1000,
        .lcd_cmd_bits = 8,
        .lcd_param_bits = 8,
        .spi_mode = 2,
        .trans_queue_depth = 10,
        .on_color_trans_done = color_transfer_done,
        .user_ctx = color_done_sem,
    };
    ESP_RETURN_ON_ERROR(esp_lcd_new_panel_io_spi((esp_lcd_spi_bus_handle_t)LCD_HOST, &io_cfg, &io), TAG, "lcd io");

    esp_lcd_panel_dev_config_t panel_cfg = {
        .reset_gpio_num = GPIO_NUM_NC,
        .rgb_ele_order = LCD_RGB_ELEMENT_ORDER_RGB,
        .bits_per_pixel = 16,
    };
    ESP_RETURN_ON_ERROR(esp_lcd_new_panel_st7789(io, &panel_cfg, &panel), TAG, "st7789 panel");
    ESP_RETURN_ON_ERROR(esp_lcd_panel_reset(panel), TAG, "panel reset");
    ESP_RETURN_ON_ERROR(szp_pca9557_set_lcd_cs(false), TAG, "lcd cs low");
    ESP_RETURN_ON_ERROR(esp_lcd_panel_init(panel), TAG, "panel init");
    ESP_RETURN_ON_ERROR(esp_lcd_panel_invert_color(panel, true), TAG, "panel invert");
    ESP_RETURN_ON_ERROR(esp_lcd_panel_swap_xy(panel, true), TAG, "panel swap xy");
    ESP_RETURN_ON_ERROR(esp_lcd_panel_mirror(panel, true, false), TAG, "panel mirror");
    ESP_RETURN_ON_ERROR(esp_lcd_panel_disp_on_off(panel, true), TAG, "panel on");
    return backlight_on();
}

int szp_display_native_set_enabled(bool enabled)
{
    if (panel == NULL) return ESP_ERR_INVALID_STATE;
    ESP_RETURN_ON_ERROR(esp_lcd_panel_disp_on_off(panel, enabled), TAG, "panel enabled");
    if (!enabled) {
        return backlight_set_brightness(0);
    }
    return backlight_set_brightness(backlight_brightness);
}

int szp_display_native_set_brightness(uint8_t brightness)
{
    if (panel == NULL) return ESP_ERR_INVALID_STATE;
    backlight_brightness = brightness;
    return backlight_set_brightness(brightness);
}

int szp_display_native_draw_rgb565(uint16_t x, uint16_t y, uint16_t w, uint16_t h, const uint16_t *pixels, size_t len)
{
    if (panel == NULL || pixels == NULL) return ESP_ERR_INVALID_STATE;
    if ((size_t)w * (size_t)h > len) return ESP_ERR_INVALID_SIZE;
    if ((uint32_t)x + w > LCD_WIDTH || (uint32_t)y + h > LCD_HEIGHT) return ESP_ERR_INVALID_ARG;

    while (xSemaphoreTake(color_done_sem, 0) == pdTRUE) {}
    uint32_t seq = ++draw_seq;
    int64_t started_us = esp_timer_get_time();
    ESP_LOGI(
        TAG,
        "draw begin seq=%u x=%u y=%u w=%u h=%u len=%u",
        (unsigned)seq,
        (unsigned)x,
        (unsigned)y,
        (unsigned)w,
        (unsigned)h,
        (unsigned)len);
    ESP_RETURN_ON_ERROR(esp_lcd_panel_draw_bitmap(panel, x, y, x + w, y + h, pixels), TAG, "draw bitmap");
    ESP_LOGI(TAG, "draw queued seq=%u", (unsigned)seq);
    if (xSemaphoreTake(color_done_sem, pdMS_TO_TICKS(LCD_DRAW_WAIT_TIMEOUT_MS)) != pdTRUE) {
        int64_t elapsed_us = esp_timer_get_time() - started_us;
        ESP_LOGE(
            TAG,
            "draw wait timeout seq=%u x=%u y=%u w=%u h=%u len=%u elapsed_ms=%lld",
            (unsigned)seq,
            (unsigned)x,
            (unsigned)y,
            (unsigned)w,
            (unsigned)h,
            (unsigned)len,
            (long long)(elapsed_us / 1000));
        return ESP_ERR_TIMEOUT;
    }

    int64_t elapsed_us = esp_timer_get_time() - started_us;
    ESP_LOGI(TAG, "draw done seq=%u elapsed_ms=%lld", (unsigned)seq, (long long)(elapsed_us / 1000));
    if (elapsed_us >= LCD_DRAW_SLOW_US) {
        ESP_LOGW(
            TAG,
            "draw slow seq=%u x=%u y=%u w=%u h=%u len=%u elapsed_ms=%lld",
            (unsigned)seq,
            (unsigned)x,
            (unsigned)y,
            (unsigned)w,
            (unsigned)h,
            (unsigned)len,
            (long long)(elapsed_us / 1000));
    }
    return ESP_OK;
}

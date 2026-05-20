#include "wv_board.h"

#include "driver/spi_master.h"
#include "esp_check.h"
#include "esp_err.h"
#include "esp_lcd_panel_io.h"
#include "esp_lcd_panel_ops.h"
#include "esp_lcd_panel_vendor.h"
#include "esp_lcd_sh8601.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"

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
#define LCD_DRAW_SLOW_US 20000
#define LCD_DRAW_WAIT_TIMEOUT_MS 1000

static const char *TAG = "wv_display";
static esp_lcd_panel_handle_t panel;
static SemaphoreHandle_t color_done_sem;
static uint8_t brightness = 255;
static uint32_t draw_seq;

static const sh8601_lcd_init_cmd_t lcd_init_cmds[] = {
    {0x11, (uint8_t[]){0x00}, 0, 120},
    {0x44, (uint8_t[]){0x01, 0xD1}, 2, 0},
    {0x35, (uint8_t[]){0x00}, 1, 0},
    {0x53, (uint8_t[]){0x20}, 1, 10},
    {0x2A, (uint8_t[]){0x00, 0x00, 0x01, 0x6F}, 4, 0},
    {0x2B, (uint8_t[]){0x00, 0x00, 0x01, 0xBF}, 4, 0},
    {0x51, (uint8_t[]){0x00}, 1, 10},
    {0x29, (uint8_t[]){0x00}, 0, 10},
    {0x51, (uint8_t[]){0xFF}, 1, 0},
};

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

int wv_display_native_init(void)
{
    if (panel != NULL) return ESP_OK;

    ESP_LOGI(TAG, "init SH8601 display");
    color_done_sem = xSemaphoreCreateBinary();
    ESP_RETURN_ON_FALSE(color_done_sem != NULL, ESP_ERR_NO_MEM, TAG, "color semaphore");

    const spi_bus_config_t buscfg = SH8601_PANEL_BUS_QSPI_CONFIG(
        LCD_PCLK_GPIO,
        LCD_DATA0_GPIO,
        LCD_DATA1_GPIO,
        LCD_DATA2_GPIO,
        LCD_DATA3_GPIO,
        LCD_WIDTH * LCD_DRAW_ROWS * LCD_BITS_PER_PIXEL / 8);
    ESP_RETURN_ON_ERROR(spi_bus_initialize(LCD_HOST, &buscfg, SPI_DMA_CH_AUTO), TAG, "spi bus");

    esp_lcd_panel_io_handle_t io_handle = NULL;
    const esp_lcd_panel_io_spi_config_t io_config = SH8601_PANEL_IO_QSPI_CONFIG(
        LCD_CS_GPIO,
        color_transfer_done,
        color_done_sem);
    sh8601_vendor_config_t vendor_config = {
        .init_cmds = lcd_init_cmds,
        .init_cmds_size = sizeof(lcd_init_cmds) / sizeof(lcd_init_cmds[0]),
        .flags = {
            .use_qspi_interface = 1,
        },
    };
    ESP_RETURN_ON_ERROR(esp_lcd_new_panel_io_spi((esp_lcd_spi_bus_handle_t)LCD_HOST, &io_config, &io_handle), TAG, "panel io");

    const esp_lcd_panel_dev_config_t panel_config = {
        .reset_gpio_num = LCD_RST_GPIO,
        .rgb_ele_order = LCD_RGB_ELEMENT_ORDER_RGB,
        .bits_per_pixel = LCD_BITS_PER_PIXEL,
        .vendor_config = &vendor_config,
    };
    ESP_RETURN_ON_ERROR(esp_lcd_new_panel_sh8601(io_handle, &panel_config, &panel), TAG, "panel driver");
    ESP_RETURN_ON_ERROR(esp_lcd_panel_reset(panel), TAG, "panel reset");
    ESP_RETURN_ON_ERROR(esp_lcd_panel_init(panel), TAG, "panel init");
    ESP_RETURN_ON_ERROR(esp_lcd_panel_disp_on_off(panel, true), TAG, "panel on");
    return ESP_OK;
}

int wv_display_native_set_enabled(bool enabled)
{
    if (panel == NULL) return ESP_ERR_INVALID_STATE;
    ESP_RETURN_ON_ERROR(esp_lcd_panel_disp_on_off(panel, enabled), TAG, "panel enabled");
    if (enabled && brightness == 0) {
        brightness = 255;
    }
    return ESP_OK;
}

int wv_display_native_set_brightness(uint8_t value)
{
    if (panel == NULL) return ESP_ERR_INVALID_STATE;
    brightness = value;
    return ESP_OK;
}

int wv_display_native_draw_rgb565(uint16_t x, uint16_t y, uint16_t w, uint16_t h, const uint16_t *pixels, size_t len)
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

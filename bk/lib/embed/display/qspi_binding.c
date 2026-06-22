#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include <common/bk_err.h>
#include <components/bk_display.h>
#include <components/log.h>
#include <components/media_types.h>
#include <driver/gpio.h>
#include <driver/lcd_types.h>
#include "frame_buffer.h"
#include "gpio_driver.h"
#include "lcd_panel_devices.h"

#define BK_EMBED_DISPLAY_OK 0
#define BK_EMBED_DISPLAY_INVALID_ARG 1
#define BK_EMBED_DISPLAY_INVALID_STATE 2
#define BK_EMBED_DISPLAY_NO_MEM 3
#define BK_EMBED_DISPLAY_UNEXPECTED 9

#define TAG "bk_embed_display"

extern const lcd_device_t lcd_device_st77903_h0165y008t;
extern void bk_psram_frame_buffer_init(void);

static bk_display_ctlr_handle_t s_handle;
static frame_buffer_t *s_shadow;
static uint16_t s_width;
static uint16_t s_height;
static uint32_t s_frame_size;
static uint8_t s_qspi_id;
static uint8_t s_reset_pin;
static uint8_t s_backlight_pin;
static uint8_t s_brightness;
static bool s_initialized;
static bool s_enabled;
static bool s_frame_heap_initialized;

static int map_rc(bk_err_t rc)
{
    if (rc == BK_OK) {
        return BK_EMBED_DISPLAY_OK;
    }
    if (rc == BK_ERR_NULL_PARAM || rc == BK_ERR_PARAM) {
        return BK_EMBED_DISPLAY_INVALID_ARG;
    }
    return BK_EMBED_DISPLAY_UNEXPECTED;
}

static bk_err_t display_frame_free_cb(void *arg)
{
    frame_buffer_t *frame = (frame_buffer_t *)arg;
    if (frame != NULL) {
        frame_buffer_display_free(frame);
    }
    return BK_OK;
}

static void fill_frame_meta(frame_buffer_t *frame)
{
    frame->fmt = PIXEL_FMT_RGB565;
    frame->width = s_width;
    frame->height = s_height;
    frame->length = s_frame_size;
    frame->size = s_frame_size;
}

static void backlight_set(bool on)
{
    gpio_dev_unmap(s_backlight_pin);
    bk_gpio_enable_output(s_backlight_pin);
    if (on) {
        bk_gpio_pull_up(s_backlight_pin);
        bk_gpio_set_output_high(s_backlight_pin);
    } else {
        bk_gpio_pull_down(s_backlight_pin);
        bk_gpio_set_output_low(s_backlight_pin);
    }
}

int bk_embed_display_qspi_init(uint8_t qspi_id, uint8_t reset_pin, uint8_t backlight_pin)
{
    if (s_initialized) {
        return BK_EMBED_DISPLAY_OK;
    }

    s_qspi_id = qspi_id;
    s_reset_pin = reset_pin;
    s_backlight_pin = backlight_pin;
    s_width = lcd_device_st77903_h0165y008t.width;
    s_height = lcd_device_st77903_h0165y008t.height;
    s_frame_size = (uint32_t)s_width * (uint32_t)s_height * 2;

    bk_display_qspi_ctlr_config_t config = {
        .lcd_device = &lcd_device_st77903_h0165y008t,
        .qspi_id = s_qspi_id,
        .reset_pin = s_reset_pin,
        .te_pin = 0,
    };
    int rc = map_rc(bk_display_qspi_new(&s_handle, &config));
    if (rc != BK_EMBED_DISPLAY_OK) {
        return rc;
    }

    if (!s_frame_heap_initialized) {
        bk_psram_frame_buffer_init();
        s_frame_heap_initialized = true;
    }

    s_shadow = frame_buffer_display_malloc(s_frame_size);
    if (s_shadow == NULL) {
        bk_display_delete(s_handle);
        s_handle = NULL;
        return BK_EMBED_DISPLAY_NO_MEM;
    }
    memset(s_shadow->frame, 0, s_frame_size);
    fill_frame_meta(s_shadow);

    s_initialized = true;
    s_enabled = false;
    s_brightness = 0;
    return BK_EMBED_DISPLAY_OK;
}

void bk_embed_display_qspi_deinit(void)
{
    if (!s_initialized) {
        return;
    }

    if (s_enabled && s_handle != NULL) {
        bk_display_close(s_handle);
    }
    backlight_set(false);

    if (s_shadow != NULL) {
        frame_buffer_display_free(s_shadow);
        s_shadow = NULL;
    }
    if (s_handle != NULL) {
        bk_display_delete(s_handle);
        s_handle = NULL;
    }

    s_initialized = false;
    s_enabled = false;
    s_brightness = 0;
}

uint16_t bk_embed_display_qspi_width(void)
{
    return s_width;
}

uint16_t bk_embed_display_qspi_height(void)
{
    return s_height;
}

int bk_embed_display_qspi_set_enabled(bool enabled)
{
    if (!s_initialized || s_handle == NULL) {
        return BK_EMBED_DISPLAY_INVALID_STATE;
    }

    if (enabled == s_enabled) {
        backlight_set(enabled && s_brightness > 0);
        return BK_EMBED_DISPLAY_OK;
    }

    int rc = enabled ? map_rc(bk_display_open(s_handle)) : map_rc(bk_display_close(s_handle));
    if (rc != BK_EMBED_DISPLAY_OK) {
        return rc;
    }

    s_enabled = enabled;
    backlight_set(enabled && s_brightness > 0);
    return BK_EMBED_DISPLAY_OK;
}

bool bk_embed_display_qspi_enabled(void)
{
    return s_enabled;
}

int bk_embed_display_qspi_set_brightness(uint8_t level)
{
    if (!s_initialized) {
        return BK_EMBED_DISPLAY_INVALID_STATE;
    }
    s_brightness = level;
    backlight_set(s_enabled && level > 0);
    return BK_EMBED_DISPLAY_OK;
}

uint8_t bk_embed_display_qspi_brightness(void)
{
    return s_brightness;
}

int bk_embed_display_qspi_flush_rgb565(uint16_t x, uint16_t y, uint16_t w, uint16_t h, const uint16_t *pixels, size_t len)
{
    if (!s_initialized || !s_enabled || s_handle == NULL || s_shadow == NULL) {
        return BK_EMBED_DISPLAY_INVALID_STATE;
    }
    if (pixels == NULL || w == 0 || h == 0 || len < (size_t)w * (size_t)h) {
        return BK_EMBED_DISPLAY_INVALID_ARG;
    }
    if ((uint32_t)x + w > s_width || (uint32_t)y + h > s_height) {
        return BK_EMBED_DISPLAY_INVALID_ARG;
    }

    uint16_t *shadow = (uint16_t *)s_shadow->frame;
    for (uint16_t row = 0; row < h; row++) {
        memcpy(
            &shadow[((uint32_t)y + row) * s_width + x],
            &pixels[(uint32_t)row * w],
            (size_t)w * sizeof(uint16_t));
    }

    frame_buffer_t *display_frame = frame_buffer_display_malloc(s_frame_size);
    if (display_frame == NULL) {
        BK_LOGE(TAG, "display frame malloc failed\r\n");
        return BK_EMBED_DISPLAY_NO_MEM;
    }
    memcpy(display_frame->frame, s_shadow->frame, s_frame_size);
    fill_frame_meta(display_frame);

    int rc = map_rc(bk_display_flush(s_handle, display_frame, display_frame_free_cb));
    if (rc != BK_EMBED_DISPLAY_OK) {
        frame_buffer_display_free(display_frame);
        return rc;
    }

    return BK_EMBED_DISPLAY_OK;
}

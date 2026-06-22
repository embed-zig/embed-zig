#include <stdbool.h>
#include <stdint.h>

#include <common/bk_err.h>
#include <components/log.h>
#include <driver/i2c.h>
#include <driver/drv_tp.h>
#include <driver/tp.h>
#include <bk_peripheral.h>

#define BK_EMBED_TOUCH_OK 0
#define BK_EMBED_TOUCH_NO_DATA 1
#define BK_EMBED_TOUCH_INVALID_ARG 2
#define BK_EMBED_TOUCH_INVALID_STATE 3
#define BK_EMBED_TOUCH_UNEXPECTED 9

#define TAG "bk_embed_touch"

#ifndef SOC_I2C_UNIT_NUM
#define BK_EMBED_TOUCH_I2C_ID 2
#else
#define BK_EMBED_TOUCH_I2C_ID SOC_I2C_UNIT_NUM
#endif

#define GT911_I2C_ADDR      (0x28 >> 1)
#define GT911_PRODUCT_ID    0x8140
#define GT911_STATUS_REG    0x814E
#define GT911_POINT1_REG    0x814F

typedef struct {
    uint16_t x;
    uint16_t y;
    uint8_t pressed;
    uint8_t need_continue;
} bk_embed_touch_point_t;

static bool s_opened;
static uint8_t s_last_logged_pressed;
static uint32_t s_read_count;
static uint32_t s_notify_count;
static uint16_t s_width;
static uint16_t s_height;
static int s_mirror;
static uint8_t s_i2c_error_logged;

static void touch_event_notify(void *arg)
{
    (void)arg;
    s_notify_count++;
    BK_LOGI(TAG, "touch event notify count=%u\r\n", s_notify_count);
}

static int i2c_read_u16(uint8_t addr, uint16_t reg, uint8_t *data, uint16_t len)
{
    i2c_mem_param_t mem = {0};
    mem.dev_addr = addr;
    mem.mem_addr = reg;
    mem.mem_addr_size = I2C_MEM_ADDR_SIZE_16BIT;
    mem.data = data;
    mem.data_size = len;
    mem.timeout_ms = 2000;
    return bk_i2c_memory_read_v2(BK_EMBED_TOUCH_I2C_ID, &mem);
}

static int i2c_write_u16(uint8_t addr, uint16_t reg, uint8_t *data, uint16_t len)
{
    i2c_mem_param_t mem = {0};
    mem.dev_addr = addr;
    mem.mem_addr = reg;
    mem.mem_addr_size = I2C_MEM_ADDR_SIZE_16BIT;
    mem.data = data;
    mem.data_size = len;
    mem.timeout_ms = 2000;
    return bk_i2c_memory_write_v2(BK_EMBED_TOUCH_I2C_ID, &mem);
}

static void apply_mirror(uint16_t *x, uint16_t *y)
{
    if (s_mirror == TP_MIRROR_X_COORD || s_mirror == TP_MIRROR_X_Y_COORD) {
        *x = s_width - *x - 1;
    }
    if (s_mirror == TP_MIRROR_Y_COORD || s_mirror == TP_MIRROR_X_Y_COORD) {
        *y = s_height - *y - 1;
    }
}

static int read_gt911_direct(bk_embed_touch_point_t *point)
{
    uint8_t status = 0;
    int rc = i2c_read_u16(GT911_I2C_ADDR, GT911_STATUS_REG, &status, 1);
    if (rc != BK_OK) {
        if (!s_i2c_error_logged) {
            BK_LOGI(TAG, "gt911 direct status read failed rc=%d addr=0x%02x\r\n", rc, GT911_I2C_ADDR);
            s_i2c_error_logged = 1;
        }
        return BK_EMBED_TOUCH_NO_DATA;
    }
    if ((status & 0x80) == 0) {
        return BK_EMBED_TOUCH_NO_DATA;
    }

    uint8_t touch_count = status & 0x0f;
    uint8_t clear = 0;
    if (touch_count == 0) {
        (void)i2c_write_u16(GT911_I2C_ADDR, GT911_STATUS_REG, &clear, 1);
        point->x = 0;
        point->y = 0;
        point->pressed = 0;
        point->need_continue = 0;
        BK_LOGI(TAG, "gt911 direct release status=0x%02x\r\n", status);
        return BK_EMBED_TOUCH_OK;
    }

    uint8_t raw[8] = {0};
    if (i2c_read_u16(GT911_I2C_ADDR, GT911_POINT1_REG, raw, sizeof(raw)) != BK_OK) {
        (void)i2c_write_u16(GT911_I2C_ADDR, GT911_STATUS_REG, &clear, 1);
        return BK_EMBED_TOUCH_NO_DATA;
    }

    uint16_t x = (uint16_t)raw[1] | ((uint16_t)raw[2] << 8);
    uint16_t y = (uint16_t)raw[3] | ((uint16_t)raw[4] << 8);
    apply_mirror(&x, &y);
    point->x = x;
    point->y = y;
    point->pressed = 1;
    point->need_continue = touch_count > 1 ? 1 : 0;
    (void)i2c_write_u16(GT911_I2C_ADDR, GT911_STATUS_REG, &clear, 1);
    BK_LOGI(TAG, "gt911 direct pressed=%u x=%u y=%u status=0x%02x\r\n",
        touch_count,
        point->x,
        point->y,
        status);
    return BK_EMBED_TOUCH_OK;
}

int bk_embed_touch_open(uint16_t width, uint16_t height, int mirror)
{
    if (s_opened) {
        return BK_EMBED_TOUCH_OK;
    }
    if (width == 0 || height == 0 || mirror < TP_MIRROR_NONE || mirror > TP_MIRROR_X_Y_COORD) {
        return BK_EMBED_TOUCH_INVALID_ARG;
    }

    bk_peripheral_init();
    s_width = width;
    s_height = height;
    s_mirror = mirror;

    int rc = drv_tp_open(width, height, (tp_mirror_type_t)mirror);
    if (rc != kNoErr) {
        BK_LOGE(TAG, "drv_tp_open failed rc=%d\r\n", rc);
        return BK_EMBED_TOUCH_UNEXPECTED;
    }

    s_opened = true;
    s_last_logged_pressed = 0;
    s_read_count = 0;
    s_notify_count = 0;
    s_i2c_error_logged = 0;
    drv_tp_reg_touch_event(touch_event_notify, NULL);
    tp_device_t *device = bk_tp_get_device();
    if (device != NULL) {
        BK_LOGI(TAG, "touch device name=%s id=%u ppi=0x%08x\r\n", device->name, device->id, device->ppi);
    } else {
        BK_LOGI(TAG, "touch device not available\r\n");
    }
    uint8_t product_id[4] = {0};
    int product_rc = i2c_read_u16(GT911_I2C_ADDR, GT911_PRODUCT_ID, product_id, sizeof(product_id));
    uint8_t status = 0;
    int status_rc = i2c_read_u16(GT911_I2C_ADDR, GT911_STATUS_REG, &status, 1);
    BK_LOGI(TAG, "touch open width=%u height=%u mirror=%d product_rc=%d product=%02x %02x %02x %02x status_rc=%d status=0x%02x\r\n",
        width,
        height,
        mirror,
        product_rc,
        product_id[0],
        product_id[1],
        product_id[2],
        product_id[3],
        status_rc,
        status);
    return BK_EMBED_TOUCH_OK;
}

void bk_embed_touch_close(void)
{
    if (!s_opened) {
        return;
    }
    drv_tp_close();
    s_opened = false;
}

int bk_embed_touch_read(bk_embed_touch_point_t *point)
{
    if (point == NULL) {
        return BK_EMBED_TOUCH_INVALID_ARG;
    }
    if (!s_opened) {
        return BK_EMBED_TOUCH_INVALID_STATE;
    }
    s_read_count++;

    tp_point_infor_t raw = {0};
    int rc = drv_tp_read(&raw);
    if (rc != kNoErr) {
        int direct_rc = read_gt911_direct(point);
        if (direct_rc == BK_EMBED_TOUCH_OK) {
            return BK_EMBED_TOUCH_OK;
        }
        if ((s_read_count % 100) == 0) {
            uint8_t status = 0;
            int status_rc = i2c_read_u16(GT911_I2C_ADDR, GT911_STATUS_REG, &status, 1);
            BK_LOGI(TAG, "touch read tick count=%u data=0 status_rc=%d status=0x%02x\r\n",
                s_read_count,
                status_rc,
                status);
        }
        return BK_EMBED_TOUCH_NO_DATA;
    }

    point->x = raw.m_x;
    point->y = raw.m_y;
    point->pressed = raw.m_state ? 1 : 0;
    point->need_continue = raw.m_need_continue ? 1 : 0;
    if ((s_read_count % 100) == 0) {
        BK_LOGI(TAG, "touch read tick count=%u data=1\r\n", s_read_count);
    }
    if (point->pressed != s_last_logged_pressed || point->pressed) {
        BK_LOGI(TAG, "touch raw pressed=%u x=%u y=%u need_continue=%u\r\n",
            point->pressed,
            point->x,
            point->y,
            point->need_continue);
        s_last_logged_pressed = point->pressed;
    }
    return BK_EMBED_TOUCH_OK;
}

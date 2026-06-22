#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#include <common/bk_err.h>
#include <components/log.h>
#include <driver/adc.h>
#include <driver/gpio.h>
#include <driver/sdmadc.h>
#include <os/os.h>

#include "gpio_driver.h"
#include "sdmadc_hal.h"
#include "sys_driver.h"

#define BK_EMBED_ADC_OK 0
#define BK_EMBED_ADC_INVALID_ARG 1
#define BK_EMBED_ADC_UNEXPECTED 9

#define BK_EMBED_ADC_KEY_GPIO GPIO_28
#define BK_EMBED_ADC_KEY_CHAN SDMADC_4
#define BK_EMBED_ADC_STALE_SAMPLES 64
#define BK_EMBED_ADC_AVG_SAMPLES 8
#define BK_EMBED_ADC_SAMPLE_SPINS 20000
#define BK_EMBED_SARADC_KEY_CHAN ADC_14
#define BK_EMBED_SARADC_TIMEOUT_MS 1000

static bool s_adc4_initialized;
static bool s_saradc14_initialized;

extern bk_err_t bk_sdmadc_start(void);
extern bk_err_t bk_sdmadc_stop(void);

static int map_rc(bk_err_t rc)
{
    if (rc == BK_OK) {
        return BK_EMBED_ADC_OK;
    }
    if (rc == BK_ERR_NULL_PARAM || rc == BK_ERR_PARAM) {
        return BK_EMBED_ADC_INVALID_ARG;
    }
    return BK_EMBED_ADC_UNEXPECTED;
}

int bk_embed_adc4_init(void)
{
    if (s_adc4_initialized) {
        return BK_EMBED_ADC_OK;
    }

    BK_LOG_ON_ERR(gpio_dev_unmap(BK_EMBED_ADC_KEY_GPIO));

    int rc = map_rc(bk_sdmadc_driver_init());
    if (rc != BK_EMBED_ADC_OK) {
        return rc;
    }
    rc = map_rc(bk_sdmadc_init());
    if (rc != BK_EMBED_ADC_OK) {
        return rc;
    }

    sdmadc_config_t config;
    memset(&config, 0, sizeof(config));
    config.samp_mode = SDMADC_CONTINUOUS_MODE;
    config.samp_numb = ONEPOINT_PER_STEP;
    config.samp_chan = BK_EMBED_ADC_KEY_CHAN;
    config.comp_bpss = 0x1;
    config.cic2_bpss = 0x1;
    config.cic2_gain = 0x2d;
    config.int_enable = 0x8;
    config.cali_offset = 0x0;
    config.cali_gains = 0x1000;

    rc = map_rc(bk_sdmadc_set_cfg(&config));
    if (rc != BK_EMBED_ADC_OK) {
        return rc;
    }
    rc = map_rc(bk_sdmadc_start());
    if (rc != BK_EMBED_ADC_OK) {
        return rc;
    }
    sdmadc_hal_disable_int();

    s_adc4_initialized = true;
    return BK_EMBED_ADC_OK;
}

static bool read_raw_sample(int16_t *raw)
{
    for (uint32_t i = 0; i < BK_EMBED_ADC_SAMPLE_SPINS; i += 1) {
        if (smdadc_hal_is_fifo_empty_int_triggered()) {
            *raw = (int16_t)sdmadc_hal_get_sample_data();
            return true;
        }
    }
    return false;
}

int bk_embed_adc4_read_voltage_mv(uint32_t *voltage_mv)
{
    if (voltage_mv == NULL) {
        return BK_EMBED_ADC_INVALID_ARG;
    }

    int rc = bk_embed_adc4_init();
    if (rc != BK_EMBED_ADC_OK) {
        return rc;
    }

    int16_t raw = 0;
    for (uint32_t i = 0; i < BK_EMBED_ADC_STALE_SAMPLES; i += 1) {
        if (!read_raw_sample(&raw)) {
            return BK_EMBED_ADC_UNEXPECTED;
        }
    }

    int32_t sum = 0;
    for (uint32_t i = 0; i < BK_EMBED_ADC_AVG_SAMPLES; i += 1) {
        if (!read_raw_sample(&raw)) {
            return BK_EMBED_ADC_UNEXPECTED;
        }
        sum += raw;
    }
    raw = (int16_t)(sum / BK_EMBED_ADC_AVG_SAMPLES);

    float voltage = bk_sdmadc_calculate_voltage(raw);
    if (voltage < 0.0f) {
        voltage = 0.0f;
    }
    *voltage_mv = (uint32_t)(voltage * 1000.0f);
    return BK_EMBED_ADC_OK;
}

int bk_embed_saradc14_init(void)
{
    if (s_saradc14_initialized) {
        return BK_EMBED_ADC_OK;
    }

    int rc = map_rc(bk_adc_chan_init_gpio(BK_EMBED_SARADC_KEY_CHAN));
    if (rc != BK_EMBED_ADC_OK) {
        return rc;
    }

    rc = map_rc(bk_adc_init(BK_EMBED_SARADC_KEY_CHAN));
    if (rc != BK_EMBED_ADC_OK) {
        return rc;
    }

    adc_config_t config;
    memset(&config, 0, sizeof(config));
    config.chan = BK_EMBED_SARADC_KEY_CHAN;
    config.adc_mode = ADC_CONTINUOUS_MODE;
    config.src_clk = ADC_SCLK_XTAL_26M;
    config.clk = 3203125;
    config.saturate_mode = ADC_SATURATE_MODE_3;
    config.steady_ctrl = 7;
    config.adc_filter = 0;

    rc = map_rc(bk_adc_set_config(&config));
    if (rc != BK_EMBED_ADC_OK) {
        return rc;
    }
    rc = map_rc(bk_adc_enable_bypass_clalibration());
    if (rc != BK_EMBED_ADC_OK) {
        return rc;
    }
    rc = map_rc(bk_adc_acquire());
    if (rc != BK_EMBED_ADC_OK) {
        return rc;
    }
    rc = map_rc(bk_adc_start());
    if (rc != BK_EMBED_ADC_OK) {
        return rc;
    }

    s_saradc14_initialized = true;
    return BK_EMBED_ADC_OK;
}

int bk_embed_saradc14_read_voltage_mv(uint32_t *voltage_mv)
{
    if (voltage_mv == NULL) {
        return BK_EMBED_ADC_INVALID_ARG;
    }

    int rc = bk_embed_saradc14_init();
    if (rc != BK_EMBED_ADC_OK) {
        return rc;
    }

    uint16_t raw = 0;
    rc = map_rc(bk_adc_set_channel(BK_EMBED_SARADC_KEY_CHAN));
    if (rc != BK_EMBED_ADC_OK) {
        return rc;
    }
    rtos_delay_milliseconds(2);
    rc = map_rc(bk_adc_read(&raw, BK_EMBED_SARADC_TIMEOUT_MS));
    if (rc != BK_EMBED_ADC_OK) {
        return rc;
    }

    *voltage_mv = (uint32_t)(((float)raw / 4096.0f * 2.0f) * 1200.0f);
    return BK_EMBED_ADC_OK;
}

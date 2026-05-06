#include <stdbool.h>
#include <stdint.h>

#include "esp_check.h"
#include "esp_err.h"

#define PCA9557_ADDR 0x19
#define PCA9557_OUTPUT_REG 0x01
#define PCA9557_CONFIG_REG 0x03
#define PCA_LCD_CS_BIT 0
#define PCA_PA_EN_BIT 1
#define PCA_DVP_PWDN_BIT 2

static const char *TAG = "szp_pca9557";
static uint8_t output_cache = 0xff;

int szp_i2c_write_reg(uint8_t address, uint8_t reg, uint8_t value);
int szp_i2c_read_reg(uint8_t address, uint8_t reg, uint8_t *value);

static esp_err_t write_output(void)
{
    return szp_i2c_write_reg(PCA9557_ADDR, PCA9557_OUTPUT_REG, output_cache);
}

int szp_pca9557_init(void)
{
    uint8_t config = 0xff;
    ESP_RETURN_ON_ERROR(szp_i2c_read_reg(PCA9557_ADDR, PCA9557_CONFIG_REG, &config), TAG, "read config");
    config &= (uint8_t)~((1u << PCA_LCD_CS_BIT) | (1u << PCA_PA_EN_BIT) | (1u << PCA_DVP_PWDN_BIT));
    ESP_RETURN_ON_ERROR(szp_i2c_write_reg(PCA9557_ADDR, PCA9557_CONFIG_REG, config), TAG, "write config");

    output_cache |= (uint8_t)(1u << PCA_LCD_CS_BIT);
    output_cache &= (uint8_t)~(1u << PCA_PA_EN_BIT);
    output_cache |= (uint8_t)(1u << PCA_DVP_PWDN_BIT);
    return write_output();
}

int szp_pca9557_set_lcd_cs(bool high)
{
    if (high) {
        output_cache |= (uint8_t)(1u << PCA_LCD_CS_BIT);
    } else {
        output_cache &= (uint8_t)~(1u << PCA_LCD_CS_BIT);
    }
    return write_output();
}

int szp_pca9557_set_pa(bool enabled)
{
    if (enabled) {
        output_cache |= (uint8_t)(1u << PCA_PA_EN_BIT);
    } else {
        output_cache &= (uint8_t)~(1u << PCA_PA_EN_BIT);
    }
    return write_output();
}

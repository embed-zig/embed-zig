#include <stdint.h>

#include "driver/i2c_master.h"
#include "esp_check.h"
#include "esp_err.h"

#define SZP_I2C_PORT I2C_NUM_0
#define SZP_I2C_SDA_GPIO 1
#define SZP_I2C_SCL_GPIO 2
#define SZP_I2C_FREQ_HZ 400000
#define SZP_I2C_TIMEOUT_MS 1000
#define SZP_ES8311_ADDR 0x18
#define SZP_PCA9557_ADDR 0x19

static const char *TAG = "szp_i2c";
static i2c_master_bus_handle_t bus;
static i2c_master_dev_handle_t es8311_dev;
static i2c_master_dev_handle_t pca9557_dev;

static esp_err_t add_device(uint8_t address, i2c_master_dev_handle_t *dev)
{
    i2c_device_config_t dev_cfg = {
        .dev_addr_length = I2C_ADDR_BIT_LEN_7,
        .device_address = address,
        .scl_speed_hz = SZP_I2C_FREQ_HZ,
    };
    return i2c_master_bus_add_device(bus, &dev_cfg, dev);
}

int szp_i2c_init(void)
{
    if (bus != NULL) return ESP_OK;

    i2c_master_bus_config_t bus_cfg = {
        .i2c_port = SZP_I2C_PORT,
        .sda_io_num = SZP_I2C_SDA_GPIO,
        .scl_io_num = SZP_I2C_SCL_GPIO,
        .clk_source = I2C_CLK_SRC_DEFAULT,
        .glitch_ignore_cnt = 7,
        .flags.enable_internal_pullup = true,
    };
    ESP_RETURN_ON_ERROR(i2c_new_master_bus(&bus_cfg, &bus), TAG, "new i2c bus");
    ESP_RETURN_ON_ERROR(add_device(SZP_ES8311_ADDR, &es8311_dev), TAG, "add es8311");
    ESP_RETURN_ON_ERROR(add_device(SZP_PCA9557_ADDR, &pca9557_dev), TAG, "add pca9557");
    return ESP_OK;
}

static i2c_master_dev_handle_t device_for(uint8_t address)
{
    switch (address) {
        case SZP_ES8311_ADDR:
            return es8311_dev;
        case SZP_PCA9557_ADDR:
            return pca9557_dev;
        default:
            return NULL;
    }
}

int szp_i2c_write_reg(uint8_t address, uint8_t reg, uint8_t value)
{
    i2c_master_dev_handle_t dev = device_for(address);
    if (dev == NULL) return ESP_ERR_INVALID_ARG;

    const uint8_t data[2] = {reg, value};
    return i2c_master_transmit(dev, data, sizeof(data), SZP_I2C_TIMEOUT_MS);
}

int szp_i2c_read_reg(uint8_t address, uint8_t reg, uint8_t *value)
{
    i2c_master_dev_handle_t dev = device_for(address);
    if (dev == NULL || value == NULL) return ESP_ERR_INVALID_ARG;

    return i2c_master_transmit_receive(dev, &reg, 1, value, 1, SZP_I2C_TIMEOUT_MS);
}

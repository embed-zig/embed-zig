#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "driver/i2c_master.h"
#include "esp_err.h"

const int32_t espz_embed_i2c_esp_ok = (int32_t)ESP_OK;
const int32_t espz_embed_i2c_esp_err_timeout = (int32_t)ESP_ERR_TIMEOUT;
const int32_t espz_embed_i2c_esp_err_invalid_arg = (int32_t)ESP_ERR_INVALID_ARG;
const int32_t espz_embed_i2c_esp_err_invalid_state = (int32_t)ESP_ERR_INVALID_STATE;

int32_t espz_embed_i2c_new_master_bus(
    int32_t port,
    int32_t sda_io_num,
    int32_t scl_io_num,
    uint32_t glitch_ignore_cnt,
    bool enable_internal_pullup,
    void **out_bus)
{
    i2c_master_bus_config_t bus_cfg = {
        .i2c_port = (i2c_port_num_t)port,
        .sda_io_num = (gpio_num_t)sda_io_num,
        .scl_io_num = (gpio_num_t)scl_io_num,
        .clk_source = I2C_CLK_SRC_DEFAULT,
        .glitch_ignore_cnt = glitch_ignore_cnt,
        .flags = {
            .enable_internal_pullup = enable_internal_pullup,
        },
    };
    return (int32_t)i2c_new_master_bus(&bus_cfg, (i2c_master_bus_handle_t *)out_bus);
}

int32_t espz_embed_i2c_del_master_bus(void *bus)
{
    return (int32_t)i2c_del_master_bus((i2c_master_bus_handle_t)bus);
}

int32_t espz_embed_i2c_master_get_bus_handle(int32_t port, void **out_bus)
{
    return (int32_t)i2c_master_get_bus_handle((i2c_port_num_t)port, (i2c_master_bus_handle_t *)out_bus);
}

int32_t espz_embed_i2c_master_bus_add_device(
    void *bus,
    uint8_t address,
    uint32_t scl_speed_hz,
    void **out_device)
{
    i2c_device_config_t dev_cfg = {
        .dev_addr_length = I2C_ADDR_BIT_LEN_7,
        .device_address = address,
        .scl_speed_hz = scl_speed_hz,
    };
    return (int32_t)i2c_master_bus_add_device(
        (i2c_master_bus_handle_t)bus,
        &dev_cfg,
        (i2c_master_dev_handle_t *)out_device);
}

int32_t espz_embed_i2c_master_bus_rm_device(void *device)
{
    return (int32_t)i2c_master_bus_rm_device((i2c_master_dev_handle_t)device);
}

int32_t espz_embed_i2c_master_transmit(void *device, const uint8_t *data, size_t len, int32_t timeout_ms)
{
    return (int32_t)i2c_master_transmit((i2c_master_dev_handle_t)device, data, len, timeout_ms);
}

int32_t espz_embed_i2c_master_receive(void *device, uint8_t *data, size_t len, int32_t timeout_ms)
{
    return (int32_t)i2c_master_receive((i2c_master_dev_handle_t)device, data, len, timeout_ms);
}

int32_t espz_embed_i2c_master_transmit_receive(
    void *device,
    const uint8_t *tx,
    size_t tx_len,
    uint8_t *rx,
    size_t rx_len,
    int32_t timeout_ms)
{
    return (int32_t)i2c_master_transmit_receive(
        (i2c_master_dev_handle_t)device,
        tx,
        tx_len,
        rx,
        rx_len,
        timeout_ms);
}

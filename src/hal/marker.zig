//! Shared HAL marker types for board-side peripheral classification.

pub const Kind = enum {
    led,
    led_strip,
    display,
    mic,
    speaker,
    temp_sensor,
    imu,
    gpio,
    adc,
    pwm,
    i2c,
    spi,
    uart,
    wifi,
    ble,
    hci,
    kvs,
    rtc,
    board,
};

pub const Marker = struct {
    kind: Kind,
    id: []const u8,
};

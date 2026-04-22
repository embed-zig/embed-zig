pub const command: u8 = 0x01;
pub const com_irq: u8 = 0x04;
pub const error_reg: u8 = 0x06;
pub const status2: u8 = 0x08;
pub const fifo_data: u8 = 0x09;
pub const fifo_level: u8 = 0x0A;
pub const water_level: u8 = 0x0B;
pub const control: u8 = 0x0C;
pub const bit_framing: u8 = 0x0D;
pub const coll: u8 = 0x0E;

pub const tx_mode: u8 = 0x12;
pub const rx_mode: u8 = 0x13;
pub const tx_ctrl: u8 = 0x14;
pub const tx_auto: u8 = 0x15;
pub const rx_thres: u8 = 0x18;

pub const rfcfg: u8 = 0x26;
pub const gsn: u8 = 0x27;
pub const gwgsp: u8 = 0x28;
pub const modgsp: u8 = 0x29;
pub const tmode: u8 = 0x2A;
pub const tprescaler: u8 = 0x2B;
pub const treload_hi: u8 = 0x2C;
pub const treload_lo: u8 = 0x2D;

pub const cmd_idle: u8 = 0x20;
pub const cmd_transmit: u8 = 0x04;
pub const cmd_receive: u8 = 0x08;
pub const cmd_transceive: u8 = 0x0C;
pub const cmd_authent: u8 = 0x0E;
pub const cmd_soft_reset: u8 = 0x0F;

pub const crc_enable: u8 = 0x80;
pub const start_send: u8 = 0x80;
pub const reset_collision: u8 = 0x80;

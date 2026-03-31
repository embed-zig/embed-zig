# ES7210 Register Map

Everest Semiconductor ES7210 — High Performance 4-Channel Audio ADC.
Datasheet: Revision 22.0, May 2023.

I2C address: `1000_0xx` (7-bit), where xx = AD1:AD0 pins.
- AD1=0, AD0=0 → 0x40
- AD1=0, AD0=1 → 0x41
- AD1=1, AD0=0 → 0x42
- AD1=1, AD0=1 → 0x43

> Note: The ES7210 public datasheet (11 pages) does not include a register definition
> section. Register information below is reconstructed from the driver source code,
> ESP-ADF reference implementation, and the ES7210 User Guide (separate document).

## Register Summary

| Addr | Name | Driver Enum | Group |
|------|------|-------------|-------|
| 0x00 | RESET | `reset` | Control |
| 0x01 | CLOCK_OFF | `clock_off` | Clock |
| 0x02 | MAIN_CLK | `main_clk` | Clock |
| 0x03 | MASTER_CLK | `master_clk` | Clock |
| 0x04 | LRCK_DIV_H | `lrck_div_h` | Clock |
| 0x05 | LRCK_DIV_L | `lrck_div_l` | Clock |
| 0x06 | POWER_DOWN | `power_down` | Power |
| 0x07 | OSR | `osr` | Clock |
| 0x08 | MODE_CONFIG | `mode_config` | Control |
| 0x09 | TIME_CONTROL0 | `time_control0` | Timing |
| 0x0A | TIME_CONTROL1 | `time_control1` | Timing |
| 0x11 | SDP_INTERFACE1 | `sdp_interface1` | Serial Data Port |
| 0x12 | SDP_INTERFACE2 | `sdp_interface2` | Serial Data Port |
| 0x13 | ADC_AUTOMUTE | `adc_automute` | ADC |
| 0x14 | ADC34_MUTERANGE | `adc34_muterange` | ADC |
| 0x15 | ADC12_MUTERANGE | `adc12_muterange` | ADC |
| 0x20 | ADC34_HPF2 | `adc34_hpf2` | ADC Filter |
| 0x21 | ADC34_HPF1 | `adc34_hpf1` | ADC Filter |
| 0x22 | ADC12_HPF1 | `adc12_hpf1` | ADC Filter |
| 0x23 | ADC12_HPF2 | `adc12_hpf2` | ADC Filter |
| 0x40 | ANALOG | `analog` | Analog |
| 0x41 | MIC12_BIAS | `mic12_bias` | Analog |
| 0x42 | MIC34_BIAS | `mic34_bias` | Analog |
| 0x43 | MIC1_GAIN | `mic1_gain` | Gain |
| 0x44 | MIC2_GAIN | `mic2_gain` | Gain |
| 0x45 | MIC3_GAIN | `mic3_gain` | Gain |
| 0x46 | MIC4_GAIN | `mic4_gain` | Gain |
| 0x47 | MIC1_POWER | `mic1_power` | Power |
| 0x48 | MIC2_POWER | `mic2_power` | Power |
| 0x49 | MIC3_POWER | `mic3_power` | Power |
| 0x4A | MIC4_POWER | `mic4_power` | Power |
| 0x4B | MIC12_POWER | `mic12_power` | Power |
| 0x4C | MIC34_POWER | `mic34_power` | Power |

## Register Details

### 0x00 — RESET

| Value | Meaning |
|-------|---------|
| 0xFF | Pre-reset (write before soft reset) |
| 0x41 | Soft reset (enter normal operation) |
| 0x71 | Start chip (transition state) |
| 0x00 | Normal operation (after reset sequence) |

Reset sequence: write `0xFF`, then `0x41`.

### 0x01 — CLOCK_OFF

Controls individual clock enables. Writing 0 to a bit turns that clock **on**.

| Bit | Name | Description |
|-----|------|-------------|
| 6 | — | Additional clock gate |
| 4 | MIC34_CLK | MIC3/4 ADC clock (mask: 0x15) |
| 3 | MIC12_CLK | MIC1/2 ADC clock (mask: 0x0B) |
| 0 | — | Base clock |

| Value | Meaning |
|-------|---------|
| 0x3F | All clocks off (init) |
| 0x7F | Stop all clocks (power down) |
| 0x00 | All clocks on |

### 0x02 — MAIN_CLK

| Bit | Name | Description |
|-----|------|-------------|
| 7 | DLL_EN | DLL enable |
| 6 | DOUBLER | Clock doubler enable |
| 5:0 | ADC_DIV | ADC clock divider |

### 0x03 — MASTER_CLK

| Bit | Name | Description |
|-----|------|-------------|
| 7 | MCLK_SRC | 0 = from MCLK pad, 1 = from clock doubler |

### 0x04 — LRCK_DIV_H

| Bit | Name | Description |
|-----|------|-------------|
| 7:0 | LRCK_DIV[15:8] | LRCK divider high byte (master mode) |

### 0x05 — LRCK_DIV_L

| Bit | Name | Description |
|-----|------|-------------|
| 7:0 | LRCK_DIV[7:0] | LRCK divider low byte (master mode) |

### 0x06 — POWER_DOWN

| Value | Meaning |
|-------|---------|
| 0x00 | All modules powered on |
| 0xFF | All modules powered down |

### 0x07 — OSR

| Bit | Name | Description |
|-----|------|-------------|
| 7:0 | OSR | ADC oversampling rate. Default 0x20 (32) |

### 0x08 — MODE_CONFIG

| Bit | Name | Description |
|-----|------|-------------|
| 0 | MSC | 0 = slave mode (default), 1 = master mode |

### 0x09 — TIME_CONTROL0

Timing configuration. Driver writes `0x30` during init.

### 0x0A — TIME_CONTROL1

Timing configuration. Driver writes `0x30` during init.

### 0x11 — SDP_INTERFACE1

| Bit | Name | Description |
|-----|------|-------------|
| 7:5 | WL | Word length: 0=24b, 1=20b, 2=18b, 3=16b, 4=32b |
| 1:0 | FMT | Data format: 0=I2S, 1=Left-justified, 3=DSP/PCM |

Driver init writes `0x60` (16-bit I2S).

### 0x12 — SDP_INTERFACE2

| Bit | Name | Description |
|-----|------|-------------|
| 1 | TDM_EN | 0 = normal I2S mode, 1 = TDM mode |

TDM mode is auto-enabled when 3+ microphones are selected.

### 0x14 — ADC34_MUTERANGE

| Bit | Name | Description |
|-----|------|-------------|
| 1:0 | MUTE | 0 = unmute, 3 = mute ADC3/4 |

### 0x15 — ADC12_MUTERANGE

| Bit | Name | Description |
|-----|------|-------------|
| 1:0 | MUTE | 0 = unmute, 3 = mute ADC1/2 |

### 0x20–0x23 — HPF Registers

High-pass filter coefficients for DC offset removal.

| Addr | Name | Init Value |
|------|------|------------|
| 0x20 | ADC34_HPF2 | 0x2A |
| 0x21 | ADC34_HPF1 | 0x0A |
| 0x22 | ADC12_HPF1 | 0x0A |
| 0x23 | ADC12_HPF2 | 0x2A |

### 0x40 — ANALOG

| Value | Meaning |
|-------|---------|
| 0x40 | Analog power on |
| 0x43 | Analog power on (driver init value) |
| 0xC0 | Low power mode |
| 0xFF | Power off |

### 0x41 — MIC12_BIAS

Microphone bias voltage for MIC1/MIC2.

| Value | Meaning |
|-------|---------|
| 0x77 | Normal bias |
| 0x70 | Init bias (2.87V) |
| 0x66 | Low power bias |
| 0xFF | Bias off |

### 0x42 — MIC34_BIAS

Same encoding as MIC12_BIAS, for MIC3/MIC4.

### 0x43–0x46 — MIC1–4_GAIN

Per-channel gain registers.

| Bit | Name | Description |
|-----|------|-------------|
| 4 | PGA_EN | PGA enable (+3dB boost) |
| 3:0 | GAIN | Gain value (see table below) |

**Gain Table:**

| Value | Gain |
|-------|------|
| 0 | 0 dB |
| 1 | 3 dB |
| 2 | 6 dB |
| 3 | 9 dB |
| 4 | 12 dB |
| 5 | 15 dB |
| 6 | 18 dB |
| 7 | 21 dB |
| 8 | 24 dB |
| 9 | 27 dB |
| 10 | 30 dB |
| 11 | 33 dB |
| 12 | 34.5 dB |
| 13 | 36 dB |
| 14 | 37.5 dB |

### 0x47–0x4A — MIC1–4_POWER

Per-channel power control.

| Value | Meaning |
|-------|---------|
| 0x08 | Startup value |
| 0x3F | Power on |
| 0x00 | Low power |
| 0xFF | Power off |

### 0x4B — MIC12_POWER

Combined power control for MIC1 and MIC2.

| Value | Meaning |
|-------|---------|
| 0x00 | Low power mode (enabled) |
| 0xFF | Power off |

### 0x4C — MIC34_POWER

Combined power control for MIC3 and MIC4. Same encoding as MIC12_POWER.

## Driver Register Usage Quick Reference

| API | Registers Written |
|-----|-------------------|
| `open()` | 0x00, 0x01, 0x09, 0x0A, 0x20–0x23, 0x14, 0x15, 0x08, 0x03, 0x40, 0x41, 0x42, 0x07, 0x02, 0x43–0x46, 0x4B, 0x4C, 0x12, 0x11, 0x00 |
| `setSampleRate()` | 0x02, 0x07, 0x04, 0x05 |
| `setBitsPerSample()` | 0x11 |
| `setFormat()` | 0x11 |
| `setGainAll()` | 0x43–0x46 (selected channels) |
| `setChannelGain()` | 0x43/0x44/0x45/0x46 |
| `setMute()` | 0x14, 0x15 |
| `selectMics()` | 0x43–0x46, 0x4B, 0x4C, 0x01, 0x12 |
| `start()` | 0x01, 0x06, 0x40, 0x47–0x4A, then `selectMics()` |
| `stop()` | 0x47–0x4C, 0x40, 0x01, 0x06 |

# ES8311 Register Map

Everest Semiconductor ES8311 — Low Power Mono Audio CODEC.
Datasheet: Revision 10.0, January 2021.

I2C address: `0011_00x` (7-bit), where x = CE pin. Default 0x18.

## Register Summary

| Addr | Name | Default | Group |
|------|------|---------|-------|
| 0x00 | RESET | 0x1F | Reset / Mode |
| 0x01 | CLK_MANAGER_01 | 0x00 | Clock |
| 0x02 | CLK_MANAGER_02 | 0x00 | Clock |
| 0x03 | CLK_MANAGER_03 | 0x10 | Clock |
| 0x04 | CLK_MANAGER_04 | 0x10 | Clock |
| 0x05 | CLK_MANAGER_05 | 0x00 | Clock |
| 0x06 | CLK_MANAGER_06 | 0x03 | Clock |
| 0x07 | CLK_MANAGER_07 | 0x00 | Clock |
| 0x08 | CLK_MANAGER_08 | 0xFF | Clock |
| 0x09 | SDP_IN | 0x00 | Serial Data Port |
| 0x0A | SDP_OUT | 0x00 | Serial Data Port |
| 0x0B | SYSTEM_0B | 0x00 | System |
| 0x0C | SYSTEM_0C | 0x20 | System |
| 0x0D | SYSTEM_0D | 0xFC | System |
| 0x0E | SYSTEM_0E | 0x6A | System |
| 0x0F | SYSTEM_0F | 0x00 | System |
| 0x10 | SYSTEM_10 | 0x13 | System |
| 0x11 | SYSTEM_11 | 0x7C | System |
| 0x12 | SYSTEM_12 | 0x02 | System |
| 0x13 | SYSTEM_13 | 0x40 | System |
| 0x14 | SYSTEM_14 | 0x10 | System |
| 0x15 | ADC_15 | 0x00 | ADC |
| 0x16 | ADC_16 | 0x04 | ADC |
| 0x17 | ADC_17 | 0x00 | ADC |
| 0x18 | ADC_18 | 0x00 | ADC (ALC) |
| 0x19 | ADC_19 | 0x00 | ADC (ALC) |
| 0x1A | ADC_1A | 0x00 | ADC (Automute) |
| 0x1B | ADC_1B | 0x0C | ADC (HPF) |
| 0x1C | ADC_1C | 0x4C | ADC (HPF/EQ) |
| 0x1D–0x30 | ADCEQ | 0x00 | ADC EQ coefficients |
| 0x31 | DAC_31 | 0x00 | DAC |
| 0x32 | DAC_32 | 0x00 | DAC |
| 0x33 | DAC_33 | 0x00 | DAC |
| 0x34 | DAC_34 | 0x00 | DAC (DRC) |
| 0x35 | DAC_35 | 0x00 | DAC (DRC) |
| 0x36 | DAC_36 | 0x00 | DAC |
| 0x37 | DAC_37 | 0x08 | DAC |
| 0x38–0x43 | DACEQ | 0x00 | DAC EQ coefficients |
| 0x44 | GPIO_44 | 0x00 | GPIO / DAC ref |
| 0x45 | GP_45 | 0x00 | General Purpose |
| 0xFA | I2C | 0x00 | I2C control |
| 0xFC | FLAG | 0x00 | Status flags (RO) |
| 0xFD | CHIP_ID1 | 0x83 | Chip ID (RO) |
| 0xFE | CHIP_ID2 | 0x11 | Chip ID (RO) |
| 0xFF | CHIP_VER | 0x00 | Chip version (RO) |

## Register Details

### 0x00 — RESET

| Bit | Name | Description |
|-----|------|-------------|
| 7 | CSM_ON | Chip state machine: 0 = power down (default), 1 = power on |
| 6 | MSC | 0 = slave mode (default), 1 = master mode |
| 5 | SEQ_DIS | Power up sequence: 0 = enable (default), 1 = disable |
| 4 | RST_DIG | Digital reset: 0 = not reset, 1 = reset (default) |
| 3 | RST_CMG | Clock manager reset: 0 = not reset, 1 = reset (default) |
| 2 | RST_MST | Master block reset: 0 = not reset, 1 = reset (default) |
| 1 | RST_ADC_DIG | ADC digital reset: 0 = not reset, 1 = reset (default) |
| 0 | RST_DAC_DIG | DAC digital reset: 0 = not reset, 1 = reset (default) |

Driver constants: `CSM_ON=0x80`, `MSC=0x40`, `SLAVE_MODE=0xBF`, `ALL_OFF=0x1F`.

### 0x01 — CLK_MANAGER_01

| Bit | Name | Description |
|-----|------|-------------|
| 7 | MCLK_SEL | 0 = from MCLK pad (default), 1 = from BCLK |
| 6 | MCLK_INV | 0 = normal (default), 1 = invert MCLK |
| 5 | MCLK_ON | 0 = off (default), 1 = on |
| 4 | BCLK_ON | 0 = off (default), 1 = on |
| 3 | CLKADC_ON | 0 = off (default), 1 = on |
| 2 | CLKDAC_ON | 0 = off (default), 1 = on |
| 1 | ANACLKADC_ON | 0 = off, 1 = on (default) |
| 0 | ANACLKDAC_ON | 0 = off, 1 = on (default) |

Driver uses `MCLK_ON=0x3F` (all clocks on), `INIT_OFF=0x30`.

### 0x02 — CLK_MANAGER_02

| Bit | Name | Description |
|-----|------|-------------|
| 7:5 | DIV_PRE | Pre-divide: mclk_prediv = mclkin / (DIV_PRE + 1) |
| 4:3 | MULT_PRE | Pre-multiply: 0=×1, 1=×2, 2=×4, 3=×8 |
| 2 | PATHSEL | Clock doubler path: 0 = no DFF, 1 = DFF |
| 1:0 | DELYSEL | Doubler delay: 0=5ns, 1=10ns, 2=15ns, 3=15ns |

### 0x03 — CLK_MANAGER_03

| Bit | Name | Description |
|-----|------|-------------|
| 6 | ADC_FSMODE | 0 = single speed (default), 1 = double speed |
| 5:0 | ADC_OSR | ADC oversampling rate. 16=64×Fs (default), 32=128×Fs |

### 0x04 — CLK_MANAGER_04

| Bit | Name | Description |
|-----|------|-------------|
| 6:0 | DAC_OSR | DAC oversampling rate. 16=64×Fs (default), 32=128×Fs, 64=256×Fs |

### 0x05 — CLK_MANAGER_05

| Bit | Name | Description |
|-----|------|-------------|
| 7:4 | DIV_CLKADC | adc_mclk = dig_mclk / (DIV_CLKADC + 1) |
| 3:0 | DIV_CLKDAC | dac_mclk = dig_mclk / (DIV_CLKDAC + 1) |

### 0x06 — CLK_MANAGER_06

| Bit | Name | Description |
|-----|------|-------------|
| 6 | BCLK_CON | 0 = normal continuous BCLK, 1 = stop after data xfer |
| 5 | BCLK_INV | 0 = normal (default), 1 = invert BCLK |
| 4:0 | DIV_BCLK | BCLK divider (master mode). 0–19: MCLK/(n+1), ≥20: see datasheet |

### 0x07 — CLK_MANAGER_07

| Bit | Name | Description |
|-----|------|-------------|
| 5 | TRI_BLRCK | BCLK/LRCK tri-state: 0 = normal, 1 = tri-state |
| 4 | TRI_ADCDAT | ADCDAT tri-state: 0 = normal, 1 = tri-state |
| 3:0 | DIV_LRCK[11:8] | LRCK divider high bits. LRCK = MCLK / (LRCK_DIV + 1) |

### 0x08 — CLK_MANAGER_08

| Bit | Name | Description |
|-----|------|-------------|
| 7:0 | DIV_LRCK[7:0] | LRCK divider low bits |

### 0x09 — SDP_IN (DAC input)

| Bit | Name | Description |
|-----|------|-------------|
| 7 | SDP_IN_SEL | 0 = left channel to DAC (default), 1 = right channel |
| 6 | SDP_IN_MUTE | 0 = unmute (default), 1 = mute |
| 5 | SDP_IN_LRP | Polarity: 0 = normal (default), 1 = inverted |
| 4:2 | SDP_IN_WL | Word length: 0=24b, 1=20b, 2=18b, 3=16b, 4=32b |
| 1:0 | SDP_IN_FMT | Format: 0=I2S, 1=Left-justified, 3=DSP/PCM |

### 0x0A — SDP_OUT (ADC output)

| Bit | Name | Description |
|-----|------|-------------|
| 6 | SDP_OUT_MUTE | 0 = unmute (default), 1 = mute |
| 5 | SDP_OUT_LRP | Polarity: 0 = normal (default), 1 = inverted |
| 4:2 | SDP_OUT_WL | Word length: 0=24b, 1=20b, 2=18b, 3=16b, 4=32b |
| 1:0 | SDP_OUT_FMT | Format: 0=I2S, 1=Left-justified, 3=DSP/PCM |

### 0x0D — SYSTEM_0D (Analog power)

| Bit | Name | Description |
|-----|------|-------------|
| 7 | PDN_ANA | 0 = enable analog, 1 = power down (default) |
| 6 | PDN_IBIASGEN | 0 = enable bias, 1 = power down (default) |
| 5 | PDN_ADCBIASGEN | 0 = enable ADC bias, 1 = power down (default) |
| 4 | PDN_ADCVERFGEN | 0 = enable ADC VREF, 1 = power down (default) |
| 3 | PDN_DACVREFGEN | 0 = enable DAC VREF, 1 = power down (default) |
| 2 | PDN_VREF | 0 = disable VREF, 1 = enable (default) |
| 1:0 | VMIDSEL | 0=power down, 1=normal startup, 2=normal op, 3=fast startup |

### 0x0E — SYSTEM_0E (ADC analog)

| Bit | Name | Description |
|-----|------|-------------|
| 6 | PDN_PGA | 0 = enable PGA, 1 = power down (default) |
| 5 | PDN_MOD | 0 = enable ADC modulator, 1 = power down (default) |
| 4 | RST_MOD | 0 = disable, 1 = reset modulator |
| 3 | VROI | 0 = normal impedance, 1 = low impedance (default) |
| 2 | LPVREFBUF | 0 = normal, 1 = low power reference voltage |

### 0x12 — SYSTEM_12 (DAC enable)

| Bit | Name | Description |
|-----|------|-------------|
| 1 | PDN_DAC | 0 = enable DAC, 1 = power down (default) |
| 0 | ENREFR | 0 = disable DAC output ref, 1 = enable |

### 0x14 — SYSTEM_14 (Input select)

| Bit | Name | Description |
|-----|------|-------------|
| 6 | DMIC_ON | 0 = no DMIC, 1 = enable DMIC from MIC1P |
| 4 | LINSEL | 0 = no input, 1 = select MIC1P–MIC1N |
| 3:0 | PGAGAIN | PGA gain: 0=0dB, 1=3dB, … 10=30dB (3dB steps) |

### 0x16 — ADC_16 (MIC gain scale)

| Bit | Name | Description |
|-----|------|-------------|
| 5 | ADC_SYNC | Sync filter counter with LRCK |
| 4 | ADC_INV | 0 = normal, 1 = inverted |
| 3 | ADC_RAMCLR | Clear ADC RAM |
| 2:0 | ADC_SCALE | Gain: 0=0dB, 1=6dB, 2=12dB, 3=18dB, **4=24dB** (default), 5=30dB, 6=36dB, 7=42dB |

This is the main MIC gain control used by the driver's `setMicGain()`.

### 0x17 — ADC_17 (ADC volume)

| Bit | Name | Description |
|-----|------|-------------|
| 7:0 | ADC_VOLUME | 0x00=-95.5dB, 0xBF=0dB, 0xFF=+32dB (0.5dB steps) |

### 0x31 — DAC_31 (DAC control)

| Bit | Name | Description |
|-----|------|-------------|
| 7 | DAC_DSMMUTE_TO | Mute target: 0=to 8, 1=to 7/9 |
| 6 | DAC_DSMMUTE | 0 = unmute (default), 1 = mute |
| 5 | DAC_DEMMUTE | 0 = unmute (default), 1 = mute |
| 4 | DAC_INV | 0 = normal, 1 = 180° phase inversion |
| 3 | DAC_RAMCLR | 0 = normal, 1 = clear RAM |
| 2 | DAC_DSMDITH_OFF | 0 = dither on, 1 = off |

Driver uses `MUTE_MASK=0x60` (bits 6:5) for mute control.

### 0x32 — DAC_32 (DAC volume)

| Bit | Name | Description |
|-----|------|-------------|
| 7:0 | DAC_VOLUME | 0x00=-95.5dB, 0xBF=0dB, 0xFF=+32dB (0.5dB steps) |

### 0x37 — DAC_37 (DAC ramp)

| Bit | Name | Description |
|-----|------|-------------|
| 7:4 | DAC_RAMPRATE | Ramp rate: 0=disable, 1=0.25dB/4LRCK, … 15=0.25dB/65536LRCK |
| 3 | DAC_EQBYPASS | 0 = EQ enabled (default), 1 = bypass |

### 0x44 — GPIO_44 (GPIO / DAC reference)

| Bit | Name | Description |
|-----|------|-------------|
| 7 | ADC2DAC_SEL | 0 = disable, 1 = ADC to DAC loopback |
| 6:4 | ADCDAT_SEL | Output select: 0=ADC+ADC, 4=DACL+ADC, 5=ADC+DACR, 6=DACL+DACR |
| 3 | I2C_WL | Internal use (I2C filter) |
| 2:0 | GPIO_SEL | Internal use |

Driver uses `DAC_REF_ENABLED=0x58` (ADCDAT_SEL=5: ADC+DACR for AEC reference),
`DAC_REF_DISABLED=0x08`, `I2C_FILTER=0x08`.

### 0x45 — GP_45

| Bit | Name | Description |
|-----|------|-------------|
| 7:4 | FORCECSM | Internal use |
| 0 | PULLUP_SE | BCLK/LRCK pullup: 0 = on (default), 1 = off |

### 0xFD — CHIP_ID1 (Read-Only)

Value: `0x83`.

### 0xFE — CHIP_ID2 (Read-Only)

Value: `0x11`.

### 0xFF — CHIP_VER (Read-Only)

Value: `0x00`.

## Driver Register Usage Quick Reference

| API | Registers Written |
|-----|-------------------|
| `open()` | 0x44, 0x01, 0x02, 0x03, 0x16, 0x04, 0x05, 0x0B, 0x0C, 0x10, 0x11, 0x00, 0x01, 0x06, 0x13, 0x1B, 0x1C, 0x44 |
| `setSampleRate()` | 0x02, 0x05, 0x03, 0x04, 0x07, 0x08, 0x06 |
| `setBitsPerSample()` | 0x09, 0x0A |
| `setFormat()` | 0x09, 0x0A |
| `setMicGain()` | 0x16 |
| `setVolume()` | 0x32 |
| `setMute()` | 0x31 |
| `readChipId()` | 0xFD, 0xFE |
| `enable(true)` / `start()` | 0x00, 0x01, 0x09, 0x0A, 0x17, 0x0E, 0x12, 0x14, 0x0D, 0x15, 0x37, 0x45 |
| `enable(false)` / `standby()` | 0x32, 0x17, 0x0E, 0x12, 0x14, 0x0D, 0x15, 0x02, 0x00, 0x01, 0x45, 0x02 |

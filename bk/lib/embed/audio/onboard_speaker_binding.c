#include <common/bk_include.h>
#include <components/log.h>
#include <os/mem.h>
#include <string.h>
#include "audio_play.h"
#include "audio_record.h"
#include "modules/aec.h"

#define TAG "bk_audio"

static audio_play_t *s_play = NULL;
static bool s_open = false;
static audio_record_t *s_record = NULL;
static bool s_record_open = false;
static AECContext *s_aec = NULL;
static int16_t *s_aec_ref = NULL;
static int16_t *s_aec_mic = NULL;
static int16_t *s_aec_out = NULL;
static uint32_t s_aec_frame_samples = 0;

int bk_embed_audio_onboard_speaker_init(
    uint32_t sample_rate,
    uint8_t channels,
    uint8_t bits_per_sample,
    int volume,
    uint32_t frame_size,
    uint32_t pool_size)
{
    if (s_play != NULL) {
        return BK_OK;
    }
    if (channels == 0 || bits_per_sample == 0 || sample_rate == 0 || frame_size == 0 || pool_size == 0) {
        return BK_FAIL;
    }

    audio_play_cfg_t cfg = DEFAULT_AUDIO_PLAY_CONFIG();
    cfg.nChans = channels;
    cfg.sampRate = sample_rate;
    cfg.bitsPerSample = bits_per_sample;
    cfg.volume = volume;
    cfg.frame_size = frame_size;
    cfg.pool_size = pool_size;
    cfg.play_mode = AUDIO_PLAY_MODE_DIFFEN;

    s_play = audio_play_create(AUDIO_PLAY_ONBOARD_SPEAKER, &cfg);
    if (s_play == NULL) {
        BK_LOGE(TAG, "audio_play_create failed\r\n");
        return BK_FAIL;
    }

    return BK_OK;
}

void bk_embed_audio_onboard_speaker_deinit(void)
{
    if (s_play == NULL) {
        s_open = false;
        return;
    }

    audio_play_destroy(s_play);
    s_play = NULL;
    s_open = false;
}

int bk_embed_audio_onboard_speaker_enable(void)
{
    if (s_play == NULL) {
        return BK_FAIL;
    }

    if (!s_open) {
        int rc = audio_play_open(s_play);
        if (rc != BK_OK) {
            BK_LOGE(TAG, "audio_play_open failed rc=%d\r\n", rc);
            return rc;
        }
        s_open = true;
        return BK_OK;
    }

    return audio_play_control(s_play, AUDIO_PLAY_RESUME);
}

int bk_embed_audio_onboard_speaker_disable(void)
{
    if (s_play == NULL || !s_open) {
        return BK_OK;
    }

    return audio_play_control(s_play, AUDIO_PLAY_PAUSE);
}

int bk_embed_audio_onboard_speaker_write(const uint8_t *data, size_t len)
{
    if (s_play == NULL || !s_open || data == NULL || len == 0) {
        return BK_FAIL;
    }

    return audio_play_write_data(s_play, (char *)data, (uint32_t)len);
}

int bk_embed_audio_onboard_speaker_set_volume(int volume)
{
    if (s_play == NULL) {
        return BK_FAIL;
    }

    return audio_play_set_volume(s_play, volume);
}

int bk_embed_audio_onboard_mic_init(
    uint32_t sample_rate,
    uint8_t channels,
    uint8_t bits_per_sample,
    int adc_gain,
    uint32_t frame_size,
    uint32_t pool_size)
{
    if (s_record != NULL) {
        return BK_OK;
    }
    if (channels == 0 || bits_per_sample == 0 || sample_rate == 0 || frame_size == 0 || pool_size == 0) {
        return BK_FAIL;
    }

    audio_record_cfg_t cfg = DEFAULT_AUDIO_RECORD_CONFIG();
    cfg.nChans = channels;
    cfg.sampRate = sample_rate;
    cfg.bitsPerSample = bits_per_sample;
    cfg.adc_gain = adc_gain;
    cfg.mic_mode = AUDIO_MIC_MODE_DIFFEN;
    cfg.frame_size = frame_size;
    cfg.pool_size = pool_size;

    s_record = audio_record_create(AUDIO_RECORD_ONBOARD_MIC, &cfg);
    if (s_record == NULL) {
        BK_LOGE(TAG, "audio_record_create failed\r\n");
        return BK_FAIL;
    }

    return BK_OK;
}

void bk_embed_audio_onboard_mic_deinit(void)
{
    if (s_record == NULL) {
        s_record_open = false;
        return;
    }

    audio_record_destroy(s_record);
    s_record = NULL;
    s_record_open = false;
}

int bk_embed_audio_onboard_mic_enable(void)
{
    if (s_record == NULL) {
        return BK_FAIL;
    }

    if (!s_record_open) {
        int rc = audio_record_open(s_record);
        if (rc != BK_OK) {
            BK_LOGE(TAG, "audio_record_open failed rc=%d\r\n", rc);
            return rc;
        }
        s_record_open = true;
        return BK_OK;
    }

    return audio_record_control(s_record, AUDIO_RECORD_RESUME);
}

int bk_embed_audio_onboard_mic_disable(void)
{
    if (s_record == NULL || !s_record_open) {
        return BK_OK;
    }

    return audio_record_control(s_record, AUDIO_RECORD_PAUSE);
}

int bk_embed_audio_onboard_mic_read(uint8_t *data, size_t len)
{
    if (s_record == NULL || !s_record_open || data == NULL || len == 0) {
        return BK_FAIL;
    }

    return audio_record_read_data(s_record, (char *)data, (uint32_t)len);
}

int bk_embed_audio_onboard_mic_set_gain(int adc_gain)
{
    if (s_record == NULL) {
        return BK_FAIL;
    }

    return audio_play_set_adc_gain(s_record, adc_gain);
}

int bk_embed_audio_aec_init(
    uint32_t sample_rate,
    uint32_t frame_samples,
    uint32_t delay_samples,
    uint32_t ec_depth,
    uint32_t tx_rx_thr,
    uint32_t tx_rx_flr,
    uint8_t ref_scale,
    uint8_t ns_level,
    uint8_t ns_para,
    uint32_t voice_volume,
    uint32_t drc)
{
    if (s_aec != NULL) {
        return BK_OK;
    }
    if ((sample_rate != 8000 && sample_rate != 16000) || frame_samples == 0) {
        return BK_FAIL;
    }

    uint32_t context_size = aec_size(1000);
    s_aec = (AECContext *)os_malloc(context_size);
    if (s_aec == NULL) {
        BK_LOGE(TAG, "aec malloc failed size=%u\r\n", context_size);
        return BK_FAIL;
    }

    aec_init(s_aec, (int16_t)sample_rate);

    uint32_t actual_frame_samples = 0;
    uint32_t value = 0;
    aec_ctrl(s_aec, AEC_CTRL_CMD_GET_FRAME_SAMPLE, (uint32_t)(uintptr_t)&actual_frame_samples);
    if (actual_frame_samples != frame_samples) {
        BK_LOGE(TAG, "aec frame mismatch actual=%u expected=%u\r\n", actual_frame_samples, frame_samples);
        os_free(s_aec);
        s_aec = NULL;
        return BK_FAIL;
    }

    aec_ctrl(s_aec, AEC_CTRL_CMD_GET_RX_BUF, (uint32_t)(uintptr_t)&value);
    s_aec_ref = (int16_t *)(uintptr_t)value;
    aec_ctrl(s_aec, AEC_CTRL_CMD_GET_TX_BUF, (uint32_t)(uintptr_t)&value);
    s_aec_mic = (int16_t *)(uintptr_t)value;
    aec_ctrl(s_aec, AEC_CTRL_CMD_GET_OUT_BUF, (uint32_t)(uintptr_t)&value);
    s_aec_out = (int16_t *)(uintptr_t)value;
    if (s_aec_ref == NULL || s_aec_mic == NULL || s_aec_out == NULL) {
        BK_LOGE(TAG, "aec buffer lookup failed\r\n");
        os_free(s_aec);
        s_aec = NULL;
        s_aec_ref = NULL;
        s_aec_mic = NULL;
        s_aec_out = NULL;
        return BK_FAIL;
    }

    aec_ctrl(s_aec, AEC_CTRL_CMD_SET_FLAGS, 0x1f);
    aec_ctrl(s_aec, AEC_CTRL_CMD_SET_MIC_DELAY, delay_samples);
    aec_ctrl(s_aec, AEC_CTRL_CMD_SET_EC_DEPTH, ec_depth);
    aec_ctrl(s_aec, AEC_CTRL_CMD_SET_TxRxThr, tx_rx_thr);
    aec_ctrl(s_aec, AEC_CTRL_CMD_SET_TxRxFlr, tx_rx_flr);
    aec_ctrl(s_aec, AEC_CTRL_CMD_SET_REF_SCALE, ref_scale);
    aec_ctrl(s_aec, AEC_CTRL_CMD_SET_VOL, voice_volume);
    aec_ctrl(s_aec, AEC_CTRL_CMD_SET_NS_LEVEL, ns_level);
    aec_ctrl(s_aec, AEC_CTRL_CMD_SET_NS_PARA, ns_para);
    aec_ctrl(s_aec, AEC_CTRL_CMD_SET_DRC, drc);

    s_aec_frame_samples = frame_samples;
    return BK_OK;
}

void bk_embed_audio_aec_deinit(void)
{
    if (s_aec != NULL) {
        os_free(s_aec);
    }
    s_aec = NULL;
    s_aec_ref = NULL;
    s_aec_mic = NULL;
    s_aec_out = NULL;
    s_aec_frame_samples = 0;
}

int bk_embed_audio_aec_process(
    const int16_t *ref_data,
    const int16_t *mic_data,
    int16_t *out_data,
    size_t samples)
{
    if (s_aec == NULL || ref_data == NULL || mic_data == NULL || out_data == NULL) {
        return BK_FAIL;
    }
    if (samples != s_aec_frame_samples) {
        return BK_FAIL;
    }

    memcpy(s_aec_ref, ref_data, samples * sizeof(int16_t));
    memcpy(s_aec_mic, mic_data, samples * sizeof(int16_t));
    aec_proc(s_aec, s_aec_ref, s_aec_mic, s_aec_out);
    memcpy(out_data, s_aec_out, samples * sizeof(int16_t));
    return BK_OK;
}

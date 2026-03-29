const c = @cImport({
    @cInclude("config.h");
    @cInclude("opus.h");
});

pub const OpusEncoder = c.OpusEncoder;
pub const OpusDecoder = c.OpusDecoder;

pub const OPUS_BAD_ARG = c.OPUS_BAD_ARG;
pub const OPUS_BUFFER_TOO_SMALL = c.OPUS_BUFFER_TOO_SMALL;
pub const OPUS_INTERNAL_ERROR = c.OPUS_INTERNAL_ERROR;
pub const OPUS_INVALID_PACKET = c.OPUS_INVALID_PACKET;
pub const OPUS_UNIMPLEMENTED = c.OPUS_UNIMPLEMENTED;
pub const OPUS_INVALID_STATE = c.OPUS_INVALID_STATE;
pub const OPUS_ALLOC_FAIL = c.OPUS_ALLOC_FAIL;

pub const OPUS_APPLICATION_VOIP = c.OPUS_APPLICATION_VOIP;
pub const OPUS_APPLICATION_AUDIO = c.OPUS_APPLICATION_AUDIO;
pub const OPUS_APPLICATION_RESTRICTED_LOWDELAY = c.OPUS_APPLICATION_RESTRICTED_LOWDELAY;

pub const OPUS_AUTO = c.OPUS_AUTO;
pub const OPUS_SIGNAL_VOICE = c.OPUS_SIGNAL_VOICE;
pub const OPUS_SIGNAL_MUSIC = c.OPUS_SIGNAL_MUSIC;

pub const OPUS_BANDWIDTH_NARROWBAND = c.OPUS_BANDWIDTH_NARROWBAND;
pub const OPUS_BANDWIDTH_MEDIUMBAND = c.OPUS_BANDWIDTH_MEDIUMBAND;
pub const OPUS_BANDWIDTH_WIDEBAND = c.OPUS_BANDWIDTH_WIDEBAND;
pub const OPUS_BANDWIDTH_SUPERWIDEBAND = c.OPUS_BANDWIDTH_SUPERWIDEBAND;
pub const OPUS_BANDWIDTH_FULLBAND = c.OPUS_BANDWIDTH_FULLBAND;

pub const OPUS_SET_BITRATE_REQUEST = c.OPUS_SET_BITRATE_REQUEST;
pub const OPUS_GET_BITRATE_REQUEST = c.OPUS_GET_BITRATE_REQUEST;
pub const OPUS_SET_COMPLEXITY_REQUEST = c.OPUS_SET_COMPLEXITY_REQUEST;
pub const OPUS_SET_SIGNAL_REQUEST = c.OPUS_SET_SIGNAL_REQUEST;
pub const OPUS_SET_BANDWIDTH_REQUEST = c.OPUS_SET_BANDWIDTH_REQUEST;
pub const OPUS_SET_VBR_REQUEST = c.OPUS_SET_VBR_REQUEST;
pub const OPUS_SET_DTX_REQUEST = c.OPUS_SET_DTX_REQUEST;
pub const OPUS_GET_SAMPLE_RATE_REQUEST = c.OPUS_GET_SAMPLE_RATE_REQUEST;
pub const OPUS_RESET_STATE = c.OPUS_RESET_STATE;

pub const opus_encoder_get_size = c.opus_encoder_get_size;
pub const opus_encoder_init = c.opus_encoder_init;
pub const opus_encode = c.opus_encode;
pub const opus_encode_float = c.opus_encode_float;
pub const opus_encoder_ctl = c.opus_encoder_ctl;

pub const opus_decoder_get_size = c.opus_decoder_get_size;
pub const opus_decoder_init = c.opus_decoder_init;
pub const opus_decode = c.opus_decode;
pub const opus_decode_float = c.opus_decode_float;
pub const opus_decoder_ctl = c.opus_decoder_ctl;

pub const opus_packet_get_nb_samples = c.opus_packet_get_nb_samples;
pub const opus_packet_get_nb_channels = c.opus_packet_get_nb_channels;
pub const opus_packet_get_bandwidth = c.opus_packet_get_bandwidth;
pub const opus_packet_get_nb_frames = c.opus_packet_get_nb_frames;

pub fn getVersionString() [*:0]const u8 {
    return c.opus_get_version_string();
}

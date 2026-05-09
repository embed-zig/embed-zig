const embed = @import("embed");
const esp = @import("esp");

const Mic = @import("Mic.zig");
const Processor = @import("Processor.zig");
const Speaker = @import("Speaker.zig");
const RootAudioSystem = embed.audio.AudioSystem;

pub const Type = blk: {
    var builder = embed.audio.AudioSystem.Builder(esp.grt).init();
    builder.configMic(Mic.mic_count, Mic.frame_samples_per_channel);
    builder.configSpeaker(Speaker.frame_samples_per_channel);
    builder.setProcessor(&Processor.process);
    break :blk builder.build();
};

pub const Config = Type.Config;
pub const Track = RootAudioSystem.Track;
pub const TrackCtrl = RootAudioSystem.TrackCtrl;
pub const TrackHandle = RootAudioSystem.TrackHandle;
pub const Error = RootAudioSystem.Error;

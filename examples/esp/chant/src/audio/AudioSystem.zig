const embed = @import("embed");
const board = @import("../board.zig");
const RootAudioSystem = embed.audio.AudioSystem;

pub const Type = board.AudioSystem;
pub const Config = Type.Config;
pub const Track = RootAudioSystem.Track;
pub const TrackCtrl = RootAudioSystem.TrackCtrl;
pub const TrackHandle = RootAudioSystem.TrackHandle;
pub const Error = RootAudioSystem.Error;

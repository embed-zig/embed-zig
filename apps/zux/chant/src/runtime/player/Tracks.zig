pub fn State(comptime ZuxAppType: type) type {
    return @FieldType(ZuxAppType.Store.Stores, "player").StateType;
}

pub fn Track(comptime ZuxAppType: type) type {
    return @FieldType(State(ZuxAppType), "selected");
}

pub fn make(comptime ZuxAppType: type) type {
    const TrackType = Track(ZuxAppType);

    return struct {
        pub fn name(track: TrackType) []const u8 {
            return switch (track) {
                .twinkle => "Twinkle",
                .happy_birthday => "Happy Birthday",
                .doll_bear => "Doll Bear",
            };
        }

        pub fn durationMs(track: TrackType) u32 {
            return switch (track) {
                .twinkle => 12_000,
                .happy_birthday => 16_000,
                .doll_bear => 14_000,
            };
        }
    };
}

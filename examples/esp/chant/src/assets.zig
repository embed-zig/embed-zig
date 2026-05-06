const board = @import("board.zig");

pub const Track = struct {
    id: board.Track,
    name: []const u8,
    path: [:0]const u8,
};

pub const tracks = [_]Track{
    .{
        .id = .twinkle,
        .name = "Twinkle",
        .path = "/spiffs/twinkle.ogg",
    },
    .{
        .id = .happy_birthday,
        .name = "Happy Birthday",
        .path = "/spiffs/happy_birthday.ogg",
    },
    .{
        .id = .doll_bear,
        .name = "Doll Bear",
        .path = "/spiffs/doll_bear.ogg",
    },
};

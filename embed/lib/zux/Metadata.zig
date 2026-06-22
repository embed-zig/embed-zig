const Metadata = @This();

pub const empty: Metadata = .{};

label_text: ?[]const u8 = null,
item_label_texts: []const []const u8 = &.{},

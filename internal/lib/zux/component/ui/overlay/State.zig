const stdz = @import("stdz");
const State = @This();

pub const max_name_len: usize = 64;
pub const Error = error{NameTooLong};

visible: bool = false,
name: [max_name_len]u8 = [_]u8{0} ** max_name_len,
name_len: u8 = 0,
blocking: bool = false,

pub const NameFields = struct {
    name: [max_name_len]u8,
    name_len: u8,
};

pub fn nameSlice(self: *const State) []const u8 {
    return self.name[0..@as(usize, self.name_len)];
}

pub fn setName(self: *State, next_name: []const u8) Error!bool {
    return self.setNameFields(try nameFields(next_name));
}

pub fn setNameFields(self: *State, fields: NameFields) bool {
    if (self.name_len == fields.name_len and stdz.mem.eql(u8, self.name[0..], fields.name[0..])) return false;
    self.name = fields.name;
    self.name_len = fields.name_len;
    return true;
}

pub fn nameFields(next_name: []const u8) Error!NameFields {
    if (next_name.len > max_name_len) return error.NameTooLong;

    var name = [_]u8{0} ** max_name_len;
    for (next_name, 0..) |byte, i| {
        name[i] = byte;
    }

    return .{
        .name = name,
        .name_len = @intCast(next_name.len),
    };
}

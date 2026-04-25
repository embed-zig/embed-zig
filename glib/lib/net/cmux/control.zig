const control = @This();

pub const flag: u8 = 0xF9;
pub const pf_mask: u8 = 0x10;
pub const max_dlci: u8 = 63;

pub const Role = enum {
    initiator,
    responder,
};

pub const FrameType = enum(u8) {
    dm = 0x0F,
    sabm = 0x2F,
    disc = 0x43,
    ua = 0x63,
    uih = 0xEF,
};

pub fn commandCr(role: Role) bool {
    return role == .initiator;
}

pub fn responseCr(role: Role) bool {
    return !commandCr(role);
}

pub fn isValidDlci(dlci: u16) bool {
    return dlci <= max_dlci;
}

pub fn isValidUserDlci(dlci: u16) bool {
    return dlci != 0 and isValidDlci(dlci);
}

pub fn isControlDlci(dlci: u16) bool {
    return dlci == 0;
}

pub fn frameTypeName(frame_type: FrameType) []const u8 {
    return switch (frame_type) {
        .dm => "DM",
        .sabm => "SABM",
        .disc => "DISC",
        .ua => "UA",
        .uih => "UIH",
    };
}


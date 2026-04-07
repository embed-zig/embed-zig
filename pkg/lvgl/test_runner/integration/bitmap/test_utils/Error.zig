const display_api = @import("display");

pub const Error = display_api.Display.Error || error{
    UnexpectedDraw,
    MissingDraw,
    DrawAreaMismatch,
    DrawPixelsMismatch,
};

const display_api = @import("embed").drivers;

pub const Error = display_api.Display.Error || error{
    UnexpectedDraw,
    MissingDraw,
    DrawAreaMismatch,
    DrawPixelsMismatch,
    DisplayTooSmall,
};

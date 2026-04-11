const display_api = @import("drivers");

pub const Error = display_api.Display.Error || error{
    UnexpectedDraw,
    MissingDraw,
    DrawAreaMismatch,
    DrawPixelsMismatch,
};

//! io — Go-style I/O helpers.
//!
//! This package intentionally stays on the comptime/helper side. Runtime
//! VTable contracts that are specific to a subsystem should live with that
//! subsystem (for example `http.ReadCloser` for HTTP bodies).

const io = @import("io/io.zig");

pub const bufio = @import("io/bufio.zig");
pub const BufferedReader = bufio.BufferedReader;
pub const BufferedWriter = bufio.BufferedWriter;
pub const PrefixReader = io.PrefixReader;
pub const readFull = io.readFull;
pub const readAll = io.readAll;
pub const copy = io.copy;
pub const copyBuf = io.copyBuf;
pub const writeAll = io.writeAll;
pub const test_runner = struct {
    pub const unit = @import("io/test_runner/unit.zig");
};

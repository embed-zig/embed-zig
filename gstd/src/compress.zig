const builtin_std = @import("std");
const glib = @import("glib");

const compress = glib.compress;
const flate = builtin_std.compress.flate;

pub const impl = struct {
    pub fn inflate(container: compress.Container, compressed: []const u8, out: []u8) compress.InflateError!usize {
        var reader: builtin_std.Io.Reader = .fixed(compressed);
        var writer: builtin_std.Io.Writer = .fixed(out);
        var decompressor: flate.Decompress = .init(&reader, mapContainer(container), &.{});

        return decompressor.reader.streamRemaining(&writer) catch |err| switch (err) {
            error.WriteFailed => error.OutputTooSmall,
            error.ReadFailed => mapInflateError(decompressor.err),
        };
    }
};

fn mapContainer(container: compress.Container) flate.Container {
    return switch (container) {
        .raw => .raw,
        .zlib => .zlib,
        .gzip => .gzip,
    };
}

fn mapInflateError(err: ?flate.Decompress.Error) compress.InflateError {
    return switch (err orelse return error.Unexpected) {
        error.EndOfStream => error.TruncatedInput,
        error.BadGzipHeader,
        error.BadZlibHeader,
        error.WrongGzipChecksum,
        error.WrongGzipSize,
        error.WrongZlibChecksum,
        error.InvalidCode,
        error.InvalidMatch,
        error.WrongStoredBlockNlen,
        error.InvalidBlockType,
        error.InvalidDynamicBlockHeader,
        error.OversubscribedHuffmanTree,
        error.IncompleteHuffmanTree,
        error.MissingEndOfBlockCode,
        => error.InvalidData,
        error.ReadFailed => error.Unexpected,
    };
}

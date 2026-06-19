const fs_mod = @import("fs");
const path_mod = @import("path");
const compress_mod = @import("compress");
const testing_api = @import("testing");
const tar = @import("tar.zig");

pub const checksum_file_name = ".checksum.md5.txt";

const max_checksum_bytes = 128;
const max_archive_bytes = 16 * 1024 * 1024;
const tar_block_len = 512;
const write_chunk_size = 16 * 1024;

pub fn make(comptime platform_grt: type) type {
    const std = platform_grt.std;
    const log = std.log.scoped(.archive_extract);

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,

        pub const ProgressEvent = union(enum) {
            check_file: PathEvent,
            unchanged: PathEvent,
            delete_start: PathEvent,
            delete_progress: ProgressPathEvent,
            delete_done: PathEvent,
            extract_start: PathEvent,
            extract_progress: ProgressPathEvent,
            extract_done: PathEvent,
            decode_start: PathEvent,
            decode_progress: ProgressPathEvent,
            decode_done: PathEvent,
            checksum_start: PathEvent,
            checksum_done: PathEvent,
            complete: PathEvent,
            embedded: PathEvent,
        };

        pub const PathEvent = struct {
            percent: u8,
            path: []const u8,
        };

        pub const ProgressPathEvent = struct {
            percent: u8,
            path: []const u8,
            current: usize,
            total: usize,
        };

        pub const ExtractOptions = struct {
            checksum: []const u8,
            archive_zlib: []const u8,
            path: []const u8,
            force_clean: bool = false,
            write_checksum: bool = true,
            emit_delete_progress: bool = true,
            emit_extract_progress: bool = true,
            streaming: bool = false,
            expected_archive_len: ?usize = null,
            expected_payload_len: ?usize = null,
            expected_file_count: ?usize = null,
        };

        pub const CollectedFile = struct {
            path: []u8,
            data: []u8,
        };

        const ExtractState = enum {
            current,
            missing_checksum,
            mismatch,
            forced,
        };

        const ExtractStats = struct {
            tar: tar.Stats = .{},
            archive_payload_len: usize = 0,
            file_count: usize = 0,
            delete_path_count: usize = 0,
        };

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn emit(progress: anytype, value: ProgressEvent) void {
            progress.event(value);
        }

        pub fn loadFile(self: Self, archive_zlib: []const u8, rel_path: []const u8, max_bytes: usize) ![]u8 {
            try validateRelPath(rel_path);
            const Compress = RuntimeCompress();
            const tar_bytes = try inflateArchiveAlloc(Compress, self.allocator, archive_zlib, null);
            defer self.allocator.free(tar_bytes);

            var reader = tar.Reader.init(tar_bytes);
            while (try reader.next()) |entry| {
                if (entry.kind != .file) continue;
                var entry_path_buf: [192]u8 = undefined;
                const entry_path = try entry.path(&entry_path_buf);
                try validateRelPath(entry_path);
                if (!std.mem.eql(u8, entry_path, rel_path)) continue;
                if (entry.data.len > max_bytes) return error.FileTooBig;
                return self.allocator.dupe(u8, entry.data);
            }
            return error.NotFound;
        }

        pub fn extract(self: Self, options: ExtractOptions, progress: anytype) !bool {
            const started_at = platform_grt.time.instant.now();
            log.info(
                "archive extract check start path={s} checksum_file={s} checksum={s}",
                .{ options.path, checksum_file_name, options.checksum },
            );

            const Fs = RuntimeFs();
            const extract_state = try extractState(Fs, self, options, progress);
            if (extract_state == .current) {
                log.info("archive already extracted path={s} total_ms={}", .{
                    options.path,
                    durationMs(platform_grt.time.instant.now() - started_at),
                });
                return false;
            }

            log.warn("archive re-extract required reason={s} path={s}", .{
                extractStateLabel(extract_state),
                options.path,
            });
            if (options.emit_delete_progress) {
                emit(progress, .{ .delete_start = .{ .percent = 20, .path = options.path } });
            }

            const Compress = RuntimeCompress();
            if (options.streaming and comptime Compress.supports_stream) {
                return try self.extractStreaming(Fs, Compress, options, progress, started_at);
            }

            const inflate_started_at = platform_grt.time.instant.now();
            log.info("inflate archive begin compressed={}", .{options.archive_zlib.len});
            const tar_bytes = try inflateArchiveAlloc(Compress, self.allocator, options.archive_zlib, options.expected_archive_len);
            defer self.allocator.free(tar_bytes);
            log.info("inflate archive done bytes={} elapsed_ms={}", .{
                tar_bytes.len,
                durationMs(platform_grt.time.instant.now() - inflate_started_at),
            });

            const stats = try extractStats(tar_bytes);
            if (options.expected_file_count) |expected| {
                if (stats.file_count != expected) return error.InvalidArchive;
            }
            if (options.expected_payload_len) |expected| {
                if (stats.archive_payload_len != expected) return error.InvalidArchive;
            }

            try cleanArchivePaths(Fs, options.path, tar_bytes, stats, progress, options.emit_delete_progress);
            if (options.emit_extract_progress) {
                emit(progress, .{ .extract_start = .{ .percent = 40, .path = options.path } });
            }
            try extractArchive(Fs, self, options.path, tar_bytes, stats, progress, options.emit_extract_progress);
            if (options.write_checksum) {
                try self.writeChecksum(options.path, options.checksum, progress);
            }
            log.info("archive extract complete path={s} total_ms={}", .{
                options.path,
                durationMs(platform_grt.time.instant.now() - started_at),
            });
            return true;
        }

        fn extractStreaming(self: Self, comptime Fs: type, comptime Compress: type, options: ExtractOptions, progress: anytype, started_at: u64) !bool {
            {
                var checksum_path_buf: [192]u8 = undefined;
                const checksum_path = try pathJoin(&checksum_path_buf, options.path, checksum_file_name);
                try deletePath(Fs, checksum_path);
            }
            if (options.emit_delete_progress) {
                emit(progress, .{ .delete_done = .{ .percent = 40, .path = options.path } });
            }
            if (options.emit_extract_progress) {
                emit(progress, .{ .extract_start = .{ .percent = 40, .path = options.path } });
            }

            const inflate_started_at = platform_grt.time.instant.now();
            log.info("stream archive extract begin compressed={}", .{options.archive_zlib.len});
            var sink = StreamExtractor(Fs, @TypeOf(progress)).init(options.path, options.expected_file_count, progress, options.emit_extract_progress);
            const inflated_len = Compress.inflateStream(.zlib, options.archive_zlib, &sink) catch |err| {
                log.err("stream archive inflate failed err={s} state={s} files={} extracted={} payload={} current_file_written={} remaining={} padding={} header_len={}", .{
                    @errorName(err),
                    sink.stateLabel(),
                    sink.file_count,
                    sink.extracted_file_count,
                    sink.archive_payload_len,
                    sink.current_file_written,
                    sink.remaining,
                    sink.padding_remaining,
                    sink.header_len,
                });
                sink.abort();
                return err;
            };
            sink.finish() catch |err| {
                sink.abort();
                return err;
            };

            if (options.expected_archive_len) |expected| {
                if (inflated_len != expected) return error.InvalidArchive;
            }
            if (options.expected_file_count) |expected| {
                if (sink.file_count != expected) return error.InvalidArchive;
            }
            if (options.expected_payload_len) |expected| {
                if (sink.archive_payload_len != expected) return error.InvalidArchive;
            }
            if (options.write_checksum) {
                try self.writeChecksum(options.path, options.checksum, progress);
            }
            log.info("stream archive extract done files={} archive_payload={} inflated={} inflate_ms={} total_ms={}", .{
                sink.file_count,
                sink.archive_payload_len,
                inflated_len,
                durationMs(platform_grt.time.instant.now() - inflate_started_at),
                durationMs(platform_grt.time.instant.now() - started_at),
            });
            if (options.emit_extract_progress) {
                emit(progress, .{ .extract_done = .{ .percent = 60, .path = options.path } });
            }
            return true;
        }

        pub fn collectFilesBySuffix(self: Self, archive_zlib: []const u8, suffix: []const u8, max_matches: usize) ![]CollectedFile {
            return self.collectFilesBySuffixWithArchiveLen(archive_zlib, null, suffix, max_matches);
        }

        pub fn collectFilesBySuffixWithArchiveLen(
            self: Self,
            archive_zlib: []const u8,
            expected_archive_len: ?usize,
            suffix: []const u8,
            max_matches: usize,
        ) ![]CollectedFile {
            const Compress = RuntimeCompress();
            const tar_bytes = try inflateArchiveAlloc(Compress, self.allocator, archive_zlib, expected_archive_len);
            defer self.allocator.free(tar_bytes);

            var out = try std.ArrayList(CollectedFile).initCapacity(self.allocator, 0);
            errdefer {
                for (out.items) |item| {
                    self.allocator.free(item.path);
                    self.allocator.free(item.data);
                }
                out.deinit(self.allocator);
            }

            var reader = tar.Reader.init(tar_bytes);
            while (try reader.next()) |entry| {
                if (entry.kind != .file) continue;
                var rel_path_buf: [192]u8 = undefined;
                const rel_path = try entry.path(&rel_path_buf);
                try validateRelPath(rel_path);
                if (!std.mem.endsWith(u8, rel_path, suffix)) continue;
                if (out.items.len >= max_matches) return error.TooManyFiles;

                const path_copy = try self.allocator.dupe(u8, rel_path);
                var path_owned = true;
                errdefer if (path_owned) self.allocator.free(path_copy);
                const data_copy = try self.allocator.dupe(u8, entry.data);
                var data_owned = true;
                errdefer if (data_owned) self.allocator.free(data_copy);

                try out.append(self.allocator, .{
                    .path = path_copy,
                    .data = data_copy,
                });
                path_owned = false;
                data_owned = false;
            }
            return out.toOwnedSlice(self.allocator);
        }

        pub fn freeCollectedFiles(self: Self, files: []CollectedFile) void {
            for (files) |item| {
                self.allocator.free(item.path);
                self.allocator.free(item.data);
            }
            self.allocator.free(files);
        }

        pub fn writeChecksum(self: Self, root_path: []const u8, checksum: []const u8, progress: anytype) !void {
            _ = self;
            const Fs = RuntimeFs();
            var checksum_path_buf: [192]u8 = undefined;
            const checksum_path = try pathJoin(&checksum_path_buf, root_path, checksum_file_name);
            emit(progress, .{ .checksum_start = .{ .percent = 80, .path = checksum_path } });
            try writeChecksumFile(Fs, root_path, checksum);
            emit(progress, .{ .checksum_done = .{ .percent = 100, .path = checksum_path } });
        }

        fn extractState(comptime Fs: type, self: Self, options: ExtractOptions, progress: anytype) !ExtractState {
            var checksum_path_buf: [192]u8 = undefined;
            const checksum_path = try pathJoin(&checksum_path_buf, options.path, checksum_file_name);
            emit(progress, .{ .check_file = .{ .percent = 0, .path = checksum_path } });
            if (options.force_clean) return .forced;

            const installed_checksum = Fs.readFileAlloc(self.allocator, checksum_path, max_checksum_bytes) catch |err| {
                log.info("archive checksum missing path={s} err={s} expected={s}", .{
                    checksum_path,
                    @errorName(err),
                    options.checksum,
                });
                return .missing_checksum;
            };
            defer self.allocator.free(installed_checksum);

            log.info("archive checksum read path={s} bytes={} value={s} expected={s}", .{
                checksum_path,
                installed_checksum.len,
                installed_checksum,
                options.checksum,
            });
            if (!std.mem.eql(u8, installed_checksum, options.checksum)) {
                log.warn("archive checksum mismatch path={s} got_bytes={} expected_bytes={}", .{
                    checksum_path,
                    installed_checksum.len,
                    options.checksum.len,
                });
                return .mismatch;
            }

            emit(progress, .{ .unchanged = .{ .percent = 100, .path = checksum_path } });
            return .current;
        }

        fn writeChecksumFile(comptime Fs: type, root_path: []const u8, checksum: []const u8) !void {
            var checksum_path_buf: [192]u8 = undefined;
            const checksum_path = try pathJoin(&checksum_path_buf, root_path, checksum_file_name);
            try ensureParentDirs(Fs, root_path, checksum_path);

            Fs.writeFile(checksum_path, checksum) catch |err| {
                log.err("write archive checksum failed path={s} err={s}", .{ checksum_path, @errorName(err) });
                return err;
            };
            log.info("wrote archive checksum {s}", .{checksum_path});
        }

        fn cleanArchivePaths(comptime Fs: type, root_path: []const u8, tar_bytes: []const u8, stats: ExtractStats, progress: anytype, emit_progress: bool) !void {
            const delete_total = stats.delete_path_count + 1;
            var delete_current: usize = 0;

            var checksum_path_buf: [192]u8 = undefined;
            const checksum_path = try pathJoin(&checksum_path_buf, root_path, checksum_file_name);
            try deletePath(Fs, checksum_path);
            delete_current += 1;
            if (emit_progress) {
                emit(progress, .{ .delete_progress = .{
                    .percent = deletePercent(delete_current, delete_total),
                    .path = checksum_path,
                    .current = delete_current,
                    .total = delete_total,
                } });
            }

            var reader = tar.Reader.init(tar_bytes);
            while (try reader.next()) |entry| {
                if (entry.kind != .file) continue;
                var rel_path_buf: [192]u8 = undefined;
                const rel_path = try entry.path(&rel_path_buf);
                try validateRelPath(rel_path);

                var path_buf: [320]u8 = undefined;
                const path = try pathJoin(&path_buf, root_path, rel_path);
                try deletePath(Fs, path);
                delete_current += 1;
                if (emit_progress) {
                    emit(progress, .{ .delete_progress = .{
                        .percent = deletePercent(delete_current, delete_total),
                        .path = path,
                        .current = delete_current,
                        .total = delete_total,
                    } });
                }
            }

            if (emit_progress) {
                emit(progress, .{ .delete_done = .{ .percent = 40, .path = root_path } });
            }
        }

        fn extractArchive(comptime Fs: type, self: Self, root_path: []const u8, tar_bytes: []const u8, stats: ExtractStats, progress: anytype, emit_progress: bool) !void {
            _ = self;
            const progress_total = stats.file_count;
            if (emit_progress) {
                emit(progress, .{ .extract_progress = .{
                    .percent = extractPercent(0, progress_total),
                    .path = "",
                    .current = 0,
                    .total = progress_total,
                } });
            }
            const extract_started_at = platform_grt.time.instant.now();
            var written_payload: usize = 0;
            var archive_payload: usize = 0;
            var file_count: usize = 0;
            var extracted_file_count: usize = 0;
            var reader = tar.Reader.init(tar_bytes);
            while (try reader.next()) |entry| {
                var rel_path_buf: [192]u8 = undefined;
                const rel_path = try entry.path(&rel_path_buf);
                try validateRelPath(rel_path);

                switch (entry.kind) {
                    .file => {},
                    .directory => {
                        try ensureDir(Fs, root_path, rel_path);
                        continue;
                    },
                    .other => {
                        log.info("skip tar entry path={s} kind=other", .{rel_path});
                        continue;
                    },
                }

                var full_path_buf: [320]u8 = undefined;
                const full_path = try pathJoin(&full_path_buf, root_path, rel_path);
                try ensureParentDirs(Fs, root_path, full_path);

                try extractFile(Fs, rel_path, full_path, entry.data);
                written_payload += entry.data.len;
                extracted_file_count += 1;
                archive_payload += entry.data.len;
                file_count += 1;
                if (emit_progress) {
                    emit(progress, .{ .extract_progress = .{
                        .percent = extractPercent(extracted_file_count, progress_total),
                        .path = rel_path,
                        .current = extracted_file_count,
                        .total = progress_total,
                    } });
                }
            }

            if (file_count != stats.file_count) return error.InvalidArchive;
            if (archive_payload != stats.archive_payload_len) return error.InvalidArchive;
            log.info("extract archive done files={} archive_payload={} payload={} elapsed_ms={}", .{
                file_count,
                archive_payload,
                written_payload,
                durationMs(platform_grt.time.instant.now() - extract_started_at),
            });
            if (emit_progress) {
                emit(progress, .{ .extract_done = .{ .percent = 60, .path = root_path } });
            }
        }

        fn StreamExtractor(comptime Fs: type, comptime Progress: type) type {
            return struct {
                const State = enum {
                    header,
                    data,
                    padding,
                    done,
                };

                root_path: []const u8,
                progress_total: usize,
                progress: Progress,
                emit_progress: bool,
                state: State = .header,
                header_buf: [tar_block_len]u8 = undefined,
                header_len: usize = 0,
                file: ?fs_mod.File = null,
                rel_path_buf: [192]u8 = undefined,
                rel_path_len: usize = 0,
                full_path_buf: [320]u8 = undefined,
                full_path_len: usize = 0,
                entry_size: usize = 0,
                remaining: usize = 0,
                padding_remaining: usize = 0,
                current_file_written: usize = 0,
                archive_payload_len: usize = 0,
                file_count: usize = 0,
                extracted_file_count: usize = 0,

                fn init(root_path: []const u8, expected_file_count: ?usize, progress: Progress, emit_progress: bool) @This() {
                    const progress_total = expected_file_count orelse 0;
                    if (emit_progress) {
                        emit(progress, .{ .extract_progress = .{
                            .percent = extractPercent(0, progress_total),
                            .path = "",
                            .current = 0,
                            .total = progress_total,
                        } });
                    }
                    return .{
                        .root_path = root_path,
                        .progress_total = progress_total,
                        .progress = progress,
                        .emit_progress = emit_progress,
                    };
                }

                pub fn write(self: *@This(), data: []const u8) !void {
                    var pos: usize = 0;
                    while (pos < data.len) {
                        switch (self.state) {
                            .header => {
                                const n = @min(tar_block_len - self.header_len, data.len - pos);
                                @memcpy(self.header_buf[self.header_len..][0..n], data[pos..][0..n]);
                                self.header_len += n;
                                pos += n;
                                if (self.header_len == tar_block_len) {
                                    try self.processHeader();
                                }
                            },
                            .data => {
                                const n = @min(self.remaining, data.len - pos);
                                try self.writeFileData(data[pos..][0..n]);
                                self.remaining -= n;
                                pos += n;
                                if (self.remaining == 0) {
                                    try self.finishFile();
                                    self.state = if (self.padding_remaining > 0) .padding else .header;
                                }
                            },
                            .padding => {
                                const n = @min(self.padding_remaining, data.len - pos);
                                pos += n;
                                self.padding_remaining -= n;
                                if (self.padding_remaining == 0) self.state = .header;
                            },
                            .done => {
                                if (!allZero(data[pos..])) return error.InvalidArchive;
                                return;
                            },
                        }
                    }
                }

                fn finish(self: *@This()) !void {
                    switch (self.state) {
                        .header => {
                            if (self.header_len != 0 and !allZero(self.header_buf[0..self.header_len])) return error.TruncatedArchive;
                        },
                        .done => {},
                        else => return error.TruncatedArchive,
                    }
                    if (self.file != null) return error.InvalidArchive;
                }

                fn abort(self: *@This()) void {
                    if (self.file) |file| {
                        var open_file = file;
                        open_file.deinit();
                        self.file = null;
                    }
                }

                fn stateLabel(self: *const @This()) []const u8 {
                    return switch (self.state) {
                        .header => "header",
                        .data => "data",
                        .padding => "padding",
                        .done => "done",
                    };
                }

                fn processHeader(self: *@This()) !void {
                    defer self.header_len = 0;
                    const header = self.header_buf[0..tar_block_len];
                    if (allZero(header)) {
                        self.state = .done;
                        return;
                    }

                    const entry = try parseTarHeader(header);
                    const rel_path = try entry.path(&self.rel_path_buf);
                    try validateRelPath(rel_path);
                    self.rel_path_len = rel_path.len;

                    switch (entry.kind) {
                        .file => {
                            const full_path = try pathJoin(&self.full_path_buf, self.root_path, rel_path);
                            self.full_path_len = full_path.len;
                            try ensureParentDirs(Fs, self.root_path, full_path);
                            self.file = Fs.createFile(full_path, .{
                                .read = false,
                                .truncate = true,
                                .exclusive = false,
                            }) catch |err| {
                                log.err("create archive file failed path={s} err={s}", .{ full_path, @errorName(err) });
                                return err;
                            };
                            self.entry_size = entry.size;
                            self.remaining = entry.size;
                            self.padding_remaining = try tarPaddedLen(entry.size) - entry.size;
                            self.current_file_written = 0;
                            self.archive_payload_len += entry.size;
                            self.file_count += 1;
                            log.info("stream extract archive file {s} bytes={}", .{ full_path, entry.size });
                            if (entry.size == 0) {
                                try self.finishFile();
                                self.state = if (self.padding_remaining > 0) .padding else .header;
                            } else {
                                self.state = .data;
                            }
                        },
                        .directory => {
                            try ensureDir(Fs, self.root_path, rel_path);
                            self.padding_remaining = try tarPaddedLen(entry.size);
                            self.remaining = 0;
                            self.state = if (entry.size > 0) .padding else .header;
                        },
                        .other => {
                            log.info("skip tar entry path={s} kind=other", .{rel_path});
                            self.padding_remaining = try tarPaddedLen(entry.size);
                            self.remaining = 0;
                            self.state = if (entry.size > 0 or self.padding_remaining > 0) .padding else .header;
                        },
                    }
                }

                fn writeFileData(self: *@This(), data: []const u8) !void {
                    var file = self.file orelse return error.InvalidArchive;
                    var written: usize = 0;
                    const full_path = self.full_path_buf[0..self.full_path_len];
                    while (written < data.len) {
                        const n = try file.write(data[written..]);
                        if (n == 0) return error.UnexpectedWrite;
                        written += n;
                        self.current_file_written += n;
                    }
                    self.file = file;
                    if (self.current_file_written == self.entry_size or self.current_file_written % (256 * 1024) == 0) {
                        log.info("stream archive file write progress path={s} written={}/{}", .{ full_path, self.current_file_written, self.entry_size });
                    }
                }

                fn finishFile(self: *@This()) !void {
                    var file = self.file orelse return error.InvalidArchive;
                    self.file = null;
                    const full_path = self.full_path_buf[0..self.full_path_len];
                    const rel_path = self.rel_path_buf[0..self.rel_path_len];
                    file.sync() catch |err| {
                        log.err("sync archive file failed path={s} err={s}", .{ full_path, @errorName(err) });
                        file.deinit();
                        return err;
                    };
                    file.deinit();
                    const stat = Fs.stat(full_path) catch |err| {
                        log.err("stat archive file failed path={s} err={s}", .{ full_path, @errorName(err) });
                        return err;
                    };
                    if (stat.size != self.entry_size) {
                        log.err("archive file size mismatch path={s} got={} want={}", .{ full_path, stat.size, self.entry_size });
                        return error.InstalledArchiveFileSizeMismatch;
                    }
                    self.extracted_file_count += 1;
                    log.info("stream extracted archive file {s} bytes={}", .{ full_path, self.entry_size });
                    if (self.emit_progress) {
                        emit(self.progress, .{ .extract_progress = .{
                            .percent = extractPercent(self.extracted_file_count, self.progress_total),
                            .path = rel_path,
                            .current = self.extracted_file_count,
                            .total = self.progress_total,
                        } });
                    }
                }
            };
        }

        fn inflateArchiveAlloc(comptime Compress: type, allocator: std.mem.Allocator, archive_zlib: []const u8, expected_len: ?usize) ![]u8 {
            if (expected_len) |len| {
                if (len > max_archive_bytes) return error.OutputTooSmall;
                const out = try allocator.alloc(u8, len);
                errdefer allocator.free(out);
                const written = try Compress.inflate(.zlib, archive_zlib, out);
                if (written != len) return error.InvalidArchive;
                return out;
            }

            var capacity = initialInflateCapacity(archive_zlib.len);
            while (capacity <= max_archive_bytes) {
                const out = try allocator.alloc(u8, capacity);
                errdefer allocator.free(out);

                const len = Compress.inflate(.zlib, archive_zlib, out) catch |err| switch (err) {
                    error.OutputTooSmall => {
                        allocator.free(out);
                        if (capacity == max_archive_bytes) return error.OutputTooSmall;
                        capacity = nextInflateCapacity(capacity);
                        continue;
                    },
                    else => return err,
                };
                return try allocator.realloc(out, len);
            }
            return error.OutputTooSmall;
        }

        fn initialInflateCapacity(compressed_len: usize) usize {
            const min_capacity = 64 * 1024;
            const estimated = if (compressed_len > max_archive_bytes / 2) max_archive_bytes else compressed_len * 2;
            return @min(max_archive_bytes, @max(min_capacity, estimated));
        }

        fn nextInflateCapacity(capacity: usize) usize {
            const grow = @max(capacity / 4, 256 * 1024);
            return @min(max_archive_bytes, capacity + grow);
        }

        fn extractStats(tar_bytes: []const u8) !ExtractStats {
            const archive_stats = try tar.stats(tar_bytes);
            var stats: ExtractStats = .{
                .tar = archive_stats,
                .archive_payload_len = archive_stats.file_payload_len,
                .file_count = archive_stats.file_count,
            };
            var reader = tar.Reader.init(tar_bytes);
            while (try reader.next()) |entry| {
                switch (entry.kind) {
                    .file => {
                        var rel_path_buf: [192]u8 = undefined;
                        const rel_path = try entry.path(&rel_path_buf);
                        try validateRelPath(rel_path);
                        stats.delete_path_count += 1;
                    },
                    else => {},
                }
            }
            return stats;
        }

        fn parseTarHeader(header: []const u8) !tar.Entry {
            if (header.len != tar_block_len) return error.InvalidHeader;
            try validateTarChecksum(header);
            const name = nullTerminated(header[0..100]);
            const prefix = nullTerminated(header[345..500]);
            if (name.len == 0) return error.InvalidHeader;

            return .{
                .name = name,
                .prefix = prefix,
                .kind = tarEntryKind(header[156]),
                .size = try parseTarOctal(usize, header[124..136]),
                .data = "",
                .mode = try parseTarOctal(u32, header[100..108]),
            };
        }

        fn tarEntryKind(typeflag: u8) tar.EntryKind {
            return switch (typeflag) {
                0, '0' => .file,
                '5' => .directory,
                else => .other,
            };
        }

        fn tarPaddedLen(size: usize) !usize {
            const mask: usize = tar_block_len - 1;
            if (size > std.math.maxInt(usize) - mask) return error.InvalidHeader;
            return (size + mask) & ~mask;
        }

        fn nullTerminated(field: []const u8) []const u8 {
            const end = std.mem.indexOfScalar(u8, field, 0) orelse field.len;
            return std.mem.trimRight(u8, field[0..end], " ");
        }

        fn parseTarOctal(comptime T: type, field: []const u8) !T {
            if (field.len > 0 and (field[0] & 0x80) != 0) return error.Unsupported;

            var value: T = 0;
            var saw_digit = false;
            for (field) |ch| {
                switch (ch) {
                    0, ' ' => {
                        if (saw_digit) continue;
                    },
                    '0'...'7' => {
                        saw_digit = true;
                        const digit: T = @intCast(ch - '0');
                        if (value > (std.math.maxInt(T) - digit) / 8) return error.InvalidHeader;
                        value = value * 8 + digit;
                    },
                    else => return error.InvalidHeader,
                }
            }
            return value;
        }

        fn validateTarChecksum(header: []const u8) !void {
            if (header.len != tar_block_len) return error.InvalidHeader;

            const expected = try parseTarOctal(u32, header[148..156]);
            var actual: u32 = 0;
            for (header, 0..) |byte, i| {
                actual += if (i >= 148 and i < 156) ' ' else byte;
            }
            if (actual != expected) return error.InvalidChecksum;
        }

        fn allZero(bytes: []const u8) bool {
            for (bytes) |byte| {
                if (byte != 0) return false;
            }
            return true;
        }

        fn extractFile(
            comptime Fs: type,
            rel_path: []const u8,
            full_path: []const u8,
            data: []const u8,
        ) !void {
            log.info("extract archive file {s} bytes={}", .{ full_path, data.len });

            var file = Fs.createFile(full_path, .{
                .read = false,
                .truncate = true,
                .exclusive = false,
            }) catch |err| {
                log.err("create archive file failed path={s} err={s}", .{ full_path, @errorName(err) });
                return err;
            };
            var file_open = true;
            defer if (file_open) file.deinit();

            var failed_offset: usize = 0;
            writeFileChunks(file, data, full_path, &failed_offset) catch |err| {
                log.err(
                    "write archive file failed path={s} offset={} len={} err={s}",
                    .{ full_path, failed_offset, data.len, @errorName(err) },
                );
                return err;
            };
            _ = rel_path;

            file.sync() catch |err| {
                log.err("sync archive file failed path={s} err={s}", .{ full_path, @errorName(err) });
                return err;
            };
            file.deinit();
            file_open = false;
            const stat = Fs.stat(full_path) catch |err| {
                log.err("stat archive file failed path={s} err={s}", .{ full_path, @errorName(err) });
                return err;
            };
            if (stat.size != data.len) {
                log.err("archive file size mismatch path={s} got={} want={}", .{ full_path, stat.size, data.len });
                return error.InstalledArchiveFileSizeMismatch;
            }
            log.info("extracted archive file {s} bytes={}", .{ full_path, data.len });
        }

        fn writeFileChunks(
            file: anytype,
            data: []const u8,
            full_path: []const u8,
            failed_offset: *usize,
        ) !void {
            var file_written: usize = 0;
            var last_logged: usize = 0;
            while (file_written < data.len) {
                failed_offset.* = file_written;
                const chunk_len = @min(write_chunk_size, data.len - file_written);
                const chunk = data[file_written..][0..chunk_len];
                const n = try file.write(chunk);
                if (n == 0) return error.UnexpectedWrite;
                file_written += n;
                if (file_written - last_logged >= 256 * 1024 or file_written == data.len) {
                    log.info("archive file write progress path={s} written={}/{}", .{ full_path, file_written, data.len });
                    last_logged = file_written;
                }
            }
            failed_offset.* = file_written;
        }

        fn deletePath(comptime Fs: type, path: []const u8) !void {
            Fs.deleteFile(path) catch |err| switch (err) {
                error.NotFound => {},
                else => {
                    log.warn("delete archive path failed path={s} err={s}", .{ path, @errorName(err) });
                    return err;
                },
            };
        }

        fn ensureParentDirs(comptime Fs: type, root_path: []const u8, full_path: []const u8) !void {
            if (comptime @hasDecl(Fs, "ensureParentDirs")) {
                Fs.ensureParentDirs(root_path, full_path) catch |err| switch (err) {
                    error.Unsupported => {
                        log.warn("skip parent dir create path={s} err={s}", .{ full_path, @errorName(err) });
                    },
                    else => return err,
                };
                return;
            }

            const root_len = root_path.len;
            var search_from = root_len + 1;
            while (std.mem.indexOfScalarPos(u8, full_path, search_from, '/')) |slash| {
                if (slash > root_len) {
                    Fs.makeDir(full_path[0..slash]) catch |err| switch (err) {
                        error.AlreadyExists => {},
                        error.Unsupported => {
                            log.warn("skip parent dir create path={s} err={s}", .{ full_path[0..slash], @errorName(err) });
                        },
                        else => return err,
                    };
                }
                search_from = slash + 1;
            }
        }

        fn ensureDir(comptime Fs: type, root_path: []const u8, rel_path: []const u8) !void {
            var path_buf: [192]u8 = undefined;
            const path = try pathJoin(&path_buf, root_path, rel_path);
            Fs.makeDir(path) catch |err| switch (err) {
                error.AlreadyExists => {},
                error.Unsupported => {
                    log.warn("skip tar dir create path={s} err={s}", .{ path, @errorName(err) });
                },
                else => return err,
            };
        }

        fn pathJoin(buf: []u8, root_path: []const u8, rel_path: []const u8) ![]const u8 {
            return path_mod.join(buf, root_path, rel_path);
        }

        fn extractPercent(current: usize, total: usize) u8 {
            if (total == 0) return 60;
            const span: usize = 20;
            const scaled = 40 + @divTrunc(@min(current, total) * span, total);
            return @intCast(@min(scaled, 60));
        }

        fn deletePercent(current: usize, total: usize) u8 {
            if (total == 0) return 40;
            const span: usize = 20;
            const scaled = 20 + @divTrunc(@min(current, total) * span, total);
            return @intCast(@min(scaled, 40));
        }

        fn extractStateLabel(state: ExtractState) []const u8 {
            return switch (state) {
                .current => "current",
                .missing_checksum => "missing_checksum",
                .mismatch => "mismatch",
                .forced => "forced",
            };
        }

        fn durationMs(duration: u64) u64 {
            return @intCast(@divTrunc(duration, @as(u64, 1_000_000)));
        }

        fn validateRelPath(path: []const u8) !void {
            if (path.len == 0 or path[0] == '/') return error.InvalidArchivePath;
            if (std.mem.indexOf(u8, path, "..") != null) return error.InvalidArchivePath;
        }

        fn RuntimeFs() type {
            if (comptime @hasDecl(platform_grt.fs, "impl")) {
                return fs_mod.make(platform_grt.std, platform_grt.fs.impl);
            }
            return platform_grt.fs;
        }

        fn RuntimeCompress() type {
            if (comptime @hasDecl(platform_grt.compress, "impl")) {
                return compress_mod.make(platform_grt.std, platform_grt.compress.impl);
            }
            return platform_grt.compress;
        }
    };
}

pub fn TestRunner(comptime test_std: type) testing_api.TestRunner {
    const TestCase = struct {
        fn streamsArchiveToRuntimeFs() !void {
            var state = MockFs.State.init(test_std.testing.allocator);
            defer state.deinit();
            MockFs.bind(&state);

            const archive = makeTestTar();
            var progress = Progress{};
            const Extract = make(TestPlatform);
            const extractor = Extract.init(test_std.testing.allocator);

            const changed = try extractor.extract(.{
                .checksum = "abc123",
                .archive_zlib = &archive,
                .path = "/assets",
                .force_clean = true,
                .streaming = true,
                .expected_archive_len = archive.len,
                .expected_payload_len = 8,
                .expected_file_count = 2,
            }, &progress);

            try test_std.testing.expect(changed);
            try expectFile(&state, "/assets/h106/startup/tiga_startup.pixa", "pixa");
            try expectFile(&state, "/assets/h106/fonts/NotoSansSC-Bold.ttf", "font");
            try expectFile(&state, "/assets/.checksum.md5.txt", "abc123");
            try test_std.testing.expectEqual(@as(usize, 0), state.open_files);
            try test_std.testing.expect(progress.events > 0);
        }

        fn streamingAbortClosesPartialFile() !void {
            var state = MockFs.State.init(test_std.testing.allocator);
            defer state.deinit();
            MockFs.bind(&state);

            const archive = makeTestTar();
            const truncated = archive[0 .. tar_block_len * 2 + 2];
            var progress = Progress{};
            const Extract = make(TestPlatform);
            const extractor = Extract.init(test_std.testing.allocator);

            try test_std.testing.expectError(error.TruncatedArchive, extractor.extract(.{
                .checksum = "abc123",
                .archive_zlib = truncated,
                .path = "/assets",
                .force_clean = true,
                .streaming = true,
            }, &progress));
            try test_std.testing.expectEqual(@as(usize, 0), state.open_files);
        }

        const TestPlatform = struct {
            pub const std = test_std;
            pub const fs = MockFs;
            pub const compress = IdentityCompress;
            pub const time = struct {
                pub const instant = struct {
                    pub fn now() u64 {
                        return 0;
                    }
                };
            };
        };

        const IdentityCompress = struct {
            pub const supports_stream = true;

            pub fn inflate(container: compress_mod.Container, compressed: []const u8, out: []u8) compress_mod.InflateError!usize {
                if (container != .zlib) return error.Unsupported;
                if (out.len < compressed.len) return error.OutputTooSmall;
                @memcpy(out[0..compressed.len], compressed);
                return compressed.len;
            }

            pub fn inflateStream(container: compress_mod.Container, compressed: []const u8, sink: anytype) !usize {
                if (container != .zlib) return error.Unsupported;
                var pos: usize = 0;
                const chunk_sizes = [_]usize{ 7, 113, 3, 997, 41 };
                var chunk_index: usize = 0;
                while (pos < compressed.len) {
                    const size = @min(chunk_sizes[chunk_index % chunk_sizes.len], compressed.len - pos);
                    try sink.write(compressed[pos..][0..size]);
                    pos += size;
                    chunk_index += 1;
                }
                return compressed.len;
            }
        };

        const MockFs = struct {
            var current: *State = undefined;

            const State = struct {
                allocator: test_std.mem.Allocator,
                files: test_std.StringHashMap([]u8),
                dirs: test_std.StringHashMap(void),
                open_files: usize = 0,

                fn init(allocator: test_std.mem.Allocator) State {
                    return .{
                        .allocator = allocator,
                        .files = test_std.StringHashMap([]u8).init(allocator),
                        .dirs = test_std.StringHashMap(void).init(allocator),
                    };
                }

                fn deinit(self: *State) void {
                    var file_it = self.files.iterator();
                    while (file_it.next()) |entry| {
                        self.allocator.free(entry.key_ptr.*);
                        self.allocator.free(entry.value_ptr.*);
                    }
                    self.files.deinit();

                    var dir_it = self.dirs.iterator();
                    while (dir_it.next()) |entry| {
                        self.allocator.free(entry.key_ptr.*);
                    }
                    self.dirs.deinit();
                }

                fn putFile(self: *State, path: []const u8, data: []const u8) !void {
                    if (self.files.fetchRemove(path)) |entry| {
                        self.allocator.free(entry.key);
                        self.allocator.free(entry.value);
                    }

                    const path_copy = try self.allocator.dupe(u8, path);
                    errdefer self.allocator.free(path_copy);
                    const data_copy = try self.allocator.dupe(u8, data);
                    errdefer self.allocator.free(data_copy);
                    try self.files.put(path_copy, data_copy);
                }

                fn putDir(self: *State, path: []const u8) !void {
                    if (self.dirs.contains(path)) return;
                    const path_copy = try self.allocator.dupe(u8, path);
                    errdefer self.allocator.free(path_copy);
                    try self.dirs.put(path_copy, {});
                }
            };

            pub fn bind(state: *State) void {
                current = state;
            }

            pub fn openFile(path: []const u8, options: fs_mod.OpenOptions) fs_mod.OpenFileError!fs_mod.File {
                _ = path;
                _ = options;
                return error.Unsupported;
            }

            pub fn createFile(path: []const u8, options: fs_mod.CreateOptions) fs_mod.CreateFileError!fs_mod.File {
                if (current.dirs.contains(path)) return error.Unexpected;
                if (options.exclusive and current.files.contains(path)) return error.AlreadyExists;

                const file = current.allocator.create(FileImpl) catch return error.OutOfMemory;
                file.* = .{
                    .state = current,
                    .path = current.allocator.dupe(u8, path) catch {
                        current.allocator.destroy(file);
                        return error.OutOfMemory;
                    },
                };
                current.open_files += 1;
                return fs_mod.File.init(file);
            }

            pub fn deleteFile(path: []const u8) fs_mod.DeleteFileError!void {
                if (current.files.fetchRemove(path)) |entry| {
                    current.allocator.free(entry.key);
                    current.allocator.free(entry.value);
                    return;
                }
                return error.NotFound;
            }

            pub fn makeDir(path: []const u8) fs_mod.MakeDirError!void {
                if (current.files.contains(path)) return error.AlreadyExists;
                if (current.dirs.contains(path)) return error.AlreadyExists;
                current.putDir(path) catch return error.Unexpected;
            }

            pub fn stat(path: []const u8) fs_mod.StatError!fs_mod.Stat {
                if (current.files.get(path)) |data| {
                    return .{ .size = data.len, .kind = .file };
                }
                if (current.dirs.contains(path)) return .{ .kind = .directory };
                return error.NotFound;
            }

            pub fn readFileAlloc(allocator: test_std.mem.Allocator, path: []const u8, max_bytes: usize) fs_mod.ReadFileAllocError![]u8 {
                const data = current.files.get(path) orelse return error.NotFound;
                if (data.len > max_bytes) return error.FileTooBig;
                return allocator.dupe(u8, data);
            }

            pub fn writeFile(path: []const u8, data: []const u8) fs_mod.WriteFileError!void {
                current.putFile(path, data) catch return error.OutOfMemory;
            }

            const FileImpl = struct {
                state: *State,
                path: []u8,
                buf: [64]u8 = undefined,
                len: usize = 0,
                closed: bool = false,

                pub fn read(self: *@This(), buf: []u8) fs_mod.File.ReadError!usize {
                    _ = self;
                    _ = buf;
                    return error.Unexpected;
                }

                pub fn write(self: *@This(), data: []const u8) fs_mod.File.WriteError!usize {
                    if (self.closed) return error.Unexpected;
                    if (self.len + data.len > self.buf.len) return error.NoSpaceLeft;
                    @memcpy(self.buf[self.len..][0..data.len], data);
                    self.len += data.len;
                    return data.len;
                }

                pub fn seek(self: *@This(), offset: i64, whence: fs_mod.SeekWhence) fs_mod.File.SeekError!u64 {
                    _ = self;
                    _ = offset;
                    _ = whence;
                    return error.Unsupported;
                }

                pub fn sync(self: *@This()) fs_mod.File.SyncError!void {
                    self.state.putFile(self.path, self.buf[0..self.len]) catch return error.Unexpected;
                }

                pub fn close(self: *@This()) void {
                    self.closed = true;
                }

                pub fn deinit(self: *@This()) void {
                    self.state.allocator.free(self.path);
                    self.state.open_files -= 1;
                    self.state.allocator.destroy(self);
                }
            };
        };

        const Progress = struct {
            events: usize = 0,

            pub fn event(self: *@This(), _: anytype) void {
                self.events += 1;
            }
        };

        fn expectFile(state: *MockFs.State, path: []const u8, expected: []const u8) !void {
            const actual = state.files.get(path) orelse return error.NotFound;
            try test_std.testing.expectEqualSlices(u8, expected, actual);
        }

        fn makeTestTar() [tar_block_len * 7]u8 {
            var out = [_]u8{0} ** (tar_block_len * 7);
            writeHeader(out[0..tar_block_len], "h106", '5', 0, 0o755);
            writeHeader(out[tar_block_len..][0..tar_block_len], "startup/tiga_startup.pixa", '0', 4, 0o644);
            @memcpy(out[tar_block_len * 2 ..][0..4], "pixa");
            writeHeader(out[tar_block_len * 3 ..][0..tar_block_len], "fonts/NotoSansSC-Bold.ttf", '0', 4, 0o644);
            @memcpy(out[tar_block_len * 4 ..][0..4], "font");
            @memcpy(out[tar_block_len + 345 ..][0..4], "h106");
            @memcpy(out[tar_block_len * 3 + 345 ..][0..4], "h106");
            refreshChecksum(out[tar_block_len..][0..tar_block_len]);
            refreshChecksum(out[tar_block_len * 3 ..][0..tar_block_len]);
            return out;
        }

        fn writeHeader(header: []u8, name: []const u8, typeflag: u8, size: usize, mode: u32) void {
            @memset(header, 0);
            @memcpy(header[0..name.len], name);
            writeOctal(header[100..108], mode);
            writeOctal(header[108..116], 0);
            writeOctal(header[116..124], 0);
            writeOctal(header[124..136], size);
            writeOctal(header[136..148], 0);
            @memset(header[148..156], ' ');
            header[156] = typeflag;
            @memcpy(header[257..263], "ustar\x00");
            @memcpy(header[263..265], "00");
            refreshChecksum(header);
        }

        fn refreshChecksum(header: []u8) void {
            @memset(header[148..156], ' ');
            var sum: u32 = 0;
            for (header) |byte| sum += byte;
            writeOctal(header[148..156], sum);
        }

        fn writeOctal(field: []u8, value: anytype) void {
            @memset(field, 0);
            var tmp: [32]u8 = undefined;
            const text = test_std.fmt.bufPrint(&tmp, "{o}", .{value}) catch unreachable;
            const start = field.len - 1 - text.len;
            @memset(field[0..start], '0');
            @memcpy(field[start..][0..text.len], text);
            field[field.len - 1] = 0;
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: test_std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: test_std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.streamsArchiveToRuntimeFs() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.streamingAbortClosesPartialFile() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: test_std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}

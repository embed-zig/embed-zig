const fs_mod = @import("fs");
const path_mod = @import("path");
const compress_mod = @import("compress");
const tar = @import("tar.zig");

pub const checksum_file_name = ".checksum.md5.txt";

const max_checksum_bytes = 128;
const max_archive_bytes = 16 * 1024 * 1024;
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
            const tar_bytes = try inflateArchiveAlloc(Compress, self.allocator, archive_zlib);
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
            emit(progress, .{ .delete_start = .{ .percent = 20, .path = options.path } });

            const Compress = RuntimeCompress();
            const inflate_started_at = platform_grt.time.instant.now();
            log.info("inflate archive begin compressed={}", .{options.archive_zlib.len});
            const tar_bytes = try inflateArchiveAlloc(Compress, self.allocator, options.archive_zlib);
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

            try cleanArchivePaths(Fs, options.path, tar_bytes, stats, progress);
            emit(progress, .{ .extract_start = .{ .percent = 40, .path = options.path } });
            try extractArchive(Fs, self, options.path, tar_bytes, stats, progress);
            if (options.write_checksum) {
                try self.writeChecksum(options.path, options.checksum, progress);
            }
            log.info("archive extract complete path={s} total_ms={}", .{
                options.path,
                durationMs(platform_grt.time.instant.now() - started_at),
            });
            return true;
        }

        pub fn collectFilesBySuffix(self: Self, archive_zlib: []const u8, suffix: []const u8, max_matches: usize) ![]CollectedFile {
            const Compress = RuntimeCompress();
            const tar_bytes = try inflateArchiveAlloc(Compress, self.allocator, archive_zlib);
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

        fn cleanArchivePaths(comptime Fs: type, root_path: []const u8, tar_bytes: []const u8, stats: ExtractStats, progress: anytype) !void {
            const delete_total = stats.delete_path_count + 1;
            var delete_current: usize = 0;

            var checksum_path_buf: [192]u8 = undefined;
            const checksum_path = try pathJoin(&checksum_path_buf, root_path, checksum_file_name);
            try deletePath(Fs, checksum_path);
            delete_current += 1;
            emit(progress, .{ .delete_progress = .{
                .percent = deletePercent(delete_current, delete_total),
                .path = checksum_path,
                .current = delete_current,
                .total = delete_total,
            } });

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
                emit(progress, .{ .delete_progress = .{
                    .percent = deletePercent(delete_current, delete_total),
                    .path = path,
                    .current = delete_current,
                    .total = delete_total,
                } });
            }

            emit(progress, .{ .delete_done = .{ .percent = 40, .path = root_path } });
        }

        fn extractArchive(comptime Fs: type, self: Self, root_path: []const u8, tar_bytes: []const u8, stats: ExtractStats, progress: anytype) !void {
            _ = self;
            const progress_total = stats.file_count;
            emit(progress, .{ .extract_progress = .{
                .percent = extractPercent(0, progress_total),
                .path = "",
                .current = 0,
                .total = progress_total,
            } });
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
                emit(progress, .{ .extract_progress = .{
                    .percent = extractPercent(extracted_file_count, progress_total),
                    .path = rel_path,
                    .current = extracted_file_count,
                    .total = progress_total,
                } });
            }

            if (file_count != stats.file_count) return error.InvalidArchive;
            if (archive_payload != stats.archive_payload_len) return error.InvalidArchive;
            log.info("extract archive done files={} archive_payload={} payload={} elapsed_ms={}", .{
                file_count,
                archive_payload,
                written_payload,
                durationMs(platform_grt.time.instant.now() - extract_started_at),
            });
            emit(progress, .{ .extract_done = .{ .percent = 60, .path = root_path } });
        }

        fn inflateArchiveAlloc(comptime Compress: type, allocator: std.mem.Allocator, archive_zlib: []const u8) ![]u8 {
            var capacity = initialInflateCapacity(archive_zlib.len);
            while (capacity <= max_archive_bytes) : (capacity *= 2) {
                const out = try allocator.alloc(u8, capacity);
                errdefer allocator.free(out);

                const len = Compress.inflate(.zlib, archive_zlib, out) catch |err| switch (err) {
                    error.OutputTooSmall => {
                        allocator.free(out);
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
            const estimated = compressed_len * 2;
            return @min(max_archive_bytes, @max(min_capacity, estimated));
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

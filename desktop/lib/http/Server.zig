const dep = @import("dep");
const host_std = dep.host_std;
const runtime_std = dep.embed_std.std;
const Net = dep.net.make(runtime_std);
const Http = Net.http;
const ui_assets = @import("desktop_ui_assets");

const Server = @This();

pub const AddrPort = dep.net.netip.AddrPort;
pub const Listener = dep.net.Listener;

allocator: runtime_std.mem.Allocator,
inner: Http.Server,
ui: *UiHandler,

pub const Options = struct {
    server: Http.Server.Options = .{},
    assets_dir: ?[]const u8 = null,
};

pub fn init(allocator: runtime_std.mem.Allocator, options: Options) !Server {
    var inner = try Http.Server.init(allocator, options.server);
    errdefer inner.deinit();

    const ui = try allocator.create(UiHandler);
    errdefer allocator.destroy(ui);
    ui.* = try UiHandler.init(allocator, options.assets_dir);
    errdefer ui.deinit(allocator);

    try inner.handle("/", Http.Handler.init(ui));

    return .{
        .allocator = allocator,
        .inner = inner,
        .ui = ui,
    };
}

pub fn deinit(self: *Server) void {
    self.inner.deinit();
    self.ui.deinit(self.allocator);
    self.allocator.destroy(self.ui);
    self.* = undefined;
}

pub fn serve(self: *Server, listener: Listener) !void {
    return self.inner.serve(listener);
}

pub fn listenAndServe(self: *Server, address: AddrPort) !void {
    var listener = try Net.listen(self.allocator, .{ .address = address });
    defer listener.deinit();
    try self.inner.serve(listener);
}

pub fn close(self: *Server) void {
    self.inner.close();
}

const UiHandler = struct {
    assets: ResolvedAssets,

    fn init(allocator: runtime_std.mem.Allocator, assets_dir: ?[]const u8) !@This() {
        return .{
            .assets = try resolveAssets(allocator, assets_dir),
        };
    }

    fn deinit(self: *@This(), allocator: runtime_std.mem.Allocator) void {
        self.assets.deinit(allocator);
        self.* = undefined;
    }

    pub fn serveHTTP(self: *@This(), rw: *Http.ResponseWriter, req: *Http.Request) void {
        serveUi(&self.assets, rw, req);
    }
};

const Asset = struct {
    file_name: []const u8,
    content_type: []const u8,
    body: []const u8,
};

const ResolvedAssets = struct {
    index_html: []const u8 = ui_assets.index_html,
    main_js: []const u8 = ui_assets.main_js,
    desktop_core_js: []const u8 = ui_assets.desktop_core_js,
    styles_css: []const u8 = ui_assets.styles_css,
    owns_main_js: bool = false,

    fn deinit(self: *@This(), allocator: runtime_std.mem.Allocator) void {
        if (self.owns_main_js) allocator.free(self.main_js);
        self.* = undefined;
    }
};

pub fn serveUi(
    assets: *const ResolvedAssets,
    rw: *Http.ResponseWriter,
    req: *Http.Request,
) void {
    const path = if (req.url.path.len == 0) "/" else req.url.path;

    if (lookupAsset(assets, path)) |asset| {
        return serveAsset(rw, Http.status.ok, asset.content_type, asset.body);
    }

    return serveAsset(rw, Http.status.not_found, "text/plain; charset=utf-8", "not found\n");
}

fn resolveAssets(allocator: runtime_std.mem.Allocator, assets_dir: ?[]const u8) !ResolvedAssets {
    var assets = ResolvedAssets{};

    if (assets_dir) |dir| {
        if (tryReadExternalMainJs(allocator, dir)) |main_js| {
            assets.main_js = main_js;
            assets.owns_main_js = true;
        }
    }

    return assets;
}

fn lookupAsset(assets: *const ResolvedAssets, path: []const u8) ?Asset {
    if (runtime_std.mem.eql(u8, path, "/") or runtime_std.mem.eql(u8, path, "/index.html")) {
        return .{
            .file_name = "index.html",
            .content_type = "text/html; charset=utf-8",
            .body = assets.index_html,
        };
    }
    if (runtime_std.mem.eql(u8, path, "/main.js") or runtime_std.mem.eql(u8, path, "/index.js")) {
        return .{
            .file_name = "main.js",
            .content_type = "application/javascript; charset=utf-8",
            .body = assets.main_js,
        };
    }
    if (runtime_std.mem.eql(u8, path, "/desktop-core.js")) {
        return .{
            .file_name = "desktop-core.js",
            .content_type = "application/javascript; charset=utf-8",
            .body = assets.desktop_core_js,
        };
    }
    if (runtime_std.mem.eql(u8, path, "/styles.css") or runtime_std.mem.eql(u8, path, "/index.css")) {
        return .{
            .file_name = "styles.css",
            .content_type = "text/css; charset=utf-8",
            .body = assets.styles_css,
        };
    }
    return null;
}

fn tryReadExternalMainJs(
    allocator: runtime_std.mem.Allocator,
    assets_dir: []const u8,
) ?[]u8 {
    const full_path = host_std.fs.path.join(host_std.heap.page_allocator, &.{ assets_dir, "main.js" }) catch return null;
    defer host_std.heap.page_allocator.free(full_path);

    const file = openAssetFile(full_path) catch return null;
    defer file.close();

    return file.readToEndAlloc(allocator, 16 * 1024 * 1024) catch return null;
}

fn openAssetFile(full_path: []const u8) !host_std.fs.File {
    if (host_std.fs.path.isAbsolute(full_path)) {
        return host_std.fs.openFileAbsolute(full_path, .{});
    }
    return host_std.fs.cwd().openFile(full_path, .{});
}

fn serveAsset(
    rw: *Http.ResponseWriter,
    status_code: u16,
    content_type: []const u8,
    body: []const u8,
) void {
    writeResponse(rw, status_code, content_type, body);
}

fn writeResponse(
    rw: *Http.ResponseWriter,
    status_code: u16,
    content_type: []const u8,
    body: []const u8,
) void {
    var content_length_buf: [32]u8 = undefined;
    const content_length = runtime_std.fmt.bufPrint(&content_length_buf, "{d}", .{body.len}) catch return;

    rw.setHeader(Http.Header.cache_control, "no-store") catch return;
    rw.setHeader(Http.Header.content_type, content_type) catch return;
    rw.setHeader(Http.Header.content_length, content_length) catch return;
    rw.writeHeader(status_code) catch return;
    _ = rw.write(body) catch {};
}

pub fn TestRunner(comptime std: type) dep.testing.TestRunner {
    const testing_api = dep.testing;

    const TestCase = struct {
        fn lookupAssetMapsDefaultFrontendFiles() !void {
            const assets = ResolvedAssets{};

            const index = lookupAsset(&assets, "/") orelse return error.MissingAsset;
            try std.testing.expectEqualStrings("index.html", index.file_name);
            try std.testing.expect(std.mem.indexOf(u8, index.body, "main.js") != null);

            const main = lookupAsset(&assets, "/main.js") orelse return error.MissingAsset;
            try std.testing.expectEqualStrings("main.js", main.file_name);
            try std.testing.expect(std.mem.indexOf(u8, main.body, "power-btn") != null);

            const core = lookupAsset(&assets, "/desktop-core.js") orelse return error.MissingAsset;
            try std.testing.expectEqualStrings("desktop-core.js", core.file_name);
            try std.testing.expect(std.mem.indexOf(u8, core.body, "createDesktopController") != null);

            const styles = lookupAsset(&assets, "/styles.css") orelse return error.MissingAsset;
            try std.testing.expectEqualStrings("styles.css", styles.file_name);
            try std.testing.expect(std.mem.indexOf(u8, styles.body, ".button") != null);

            const alias = lookupAsset(&assets, "/index.js") orelse return error.MissingAsset;
            try std.testing.expectEqualStrings("main.js", alias.file_name);
        }

        fn resolveAssetsOverridesOnlyMainJs() !void {
            const assets_dir = ".zig-cache/tmp/desktop-http-assets-dir-test";
            host_std.fs.cwd().deleteTree(assets_dir) catch {};
            defer host_std.fs.cwd().deleteTree(assets_dir) catch {};

            var dir = try host_std.fs.cwd().makeOpenPath(assets_dir, .{});
            defer dir.close();

            try dir.writeFile(.{
                .sub_path = "main.js",
                .data = "console.log('external main');\n",
            });

            var assets = try resolveAssets(std.testing.allocator, assets_dir);
            defer assets.deinit(std.testing.allocator);

            try std.testing.expect(assets.owns_main_js);
            try std.testing.expect(std.mem.indexOf(u8, assets.main_js, "external main") != null);
            try std.testing.expectEqualStrings(ui_assets.desktop_core_js, assets.desktop_core_js);
            try std.testing.expectEqualStrings(ui_assets.styles_css, assets.styles_css);
        }

        fn resolveAssetsFallsBackWithoutMainJs() !void {
            const assets_dir = ".zig-cache/tmp/desktop-http-assets-empty-test";
            host_std.fs.cwd().deleteTree(assets_dir) catch {};
            defer host_std.fs.cwd().deleteTree(assets_dir) catch {};

            var dir = try host_std.fs.cwd().makeOpenPath(assets_dir, .{});
            defer dir.close();

            var assets = try resolveAssets(std.testing.allocator, assets_dir);
            defer assets.deinit(std.testing.allocator);

            try std.testing.expect(!assets.owns_main_js);
            try std.testing.expectEqualStrings(ui_assets.main_js, assets.main_js);
            try std.testing.expectEqualStrings(ui_assets.desktop_core_js, assets.desktop_core_js);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.lookupAssetMapsDefaultFrontendFiles() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.resolveAssetsOverridesOnlyMainJs() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.resolveAssetsFallsBackWithoutMainJs() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}

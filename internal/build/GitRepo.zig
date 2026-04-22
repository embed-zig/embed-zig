const std = @import("std");

pub const default_cache_namespace = "embed-zig-git-repo";

pub const AddGitRepoOptions = struct {
    git_repo: []const u8,
    commit: ?[]const u8 = null,
    cache_namespace: []const u8 = default_cache_namespace,
    source_subdir: []const u8 = ".",
};

pub const GitRepo = struct {
    b: *std.Build,
    steps: Steps,
    git_repo: []const u8,
    commit: ?[]const u8,
    cache_namespace: []const u8,
    repo_key: []const u8,
    commit_key: []const u8,
    source_subdir: []const u8,
    prefix_path: []const u8,
    source_root_path: []const u8,

    const EnsureGraph = struct {
        ready: std.Build.Step,
        tail: *std.Build.Step,
    };

    pub const Steps = struct {
        graph: *EnsureGraph,
    };

    pub fn root(self: @This()) std.Build.LazyPath {
        return .{ .cwd_relative = self.source_root_path };
    }

    pub fn prefixRoot(self: @This()) std.Build.LazyPath {
        return .{ .cwd_relative = self.prefix_path };
    }

    pub fn path(self: @This(), sub_path: []const u8) std.Build.LazyPath {
        if (sub_path.len == 0 or std.mem.eql(u8, sub_path, ".")) {
            return self.root();
        }
        return .{ .cwd_relative = joinPath(self.b, self.source_root_path, sub_path) };
    }

    pub fn prefixPath(self: @This(), sub_path: []const u8) std.Build.LazyPath {
        if (sub_path.len == 0 or std.mem.eql(u8, sub_path, ".")) {
            return self.prefixRoot();
        }
        return .{ .cwd_relative = joinPath(self.b, self.prefix_path, sub_path) };
    }

    pub fn sourcePath(self: @This(), sub_path: []const u8) std.Build.LazyPath {
        return self.path(sub_path);
    }

    pub fn includePath(self: @This(), sub_path: []const u8) std.Build.LazyPath {
        return self.path(sub_path);
    }

    pub fn readyStep(self: @This()) *std.Build.Step {
        return &self.steps.graph.ready;
    }

    pub fn dependOn(self: @This(), step: *std.Build.Step) void {
        step.dependOn(&self.steps.graph.ready);
    }

    pub fn configureRunStep(self: @This(), run: *std.Build.Step.Run) void {
        run.setEnvironmentVariable("TP_BUILD_ROOT", self.b.pathFromRoot("."));
        run.setEnvironmentVariable("TP_SOURCE_ROOT", self.source_root_path);
        run.setEnvironmentVariable("TP_PREFIX_ROOT", self.prefix_path);
        run.setEnvironmentVariable("TP_GIT_REPO", self.git_repo);
        run.setEnvironmentVariable("TP_GIT_COMMIT", self.commit orelse "");
        run.setEnvironmentVariable("TP_CACHE_NAMESPACE", self.cache_namespace);
        run.setEnvironmentVariable("TP_REPO_KEY", self.repo_key);
        run.setEnvironmentVariable("TP_COMMIT_KEY", self.commit_key);
    }

    pub fn addSetupCommand(self: *@This(), command: []const []const u8) *std.Build.Step.Run {
        const run = self.b.addSystemCommand(command);
        self.configureRunStep(run);
        run.step.dependOn(self.steps.graph.tail);
        self.steps.graph.tail = &run.step;
        self.steps.graph.ready.dependOn(&run.step);
        return run;
    }
};

pub fn addGitRepo(b: *std.Build, opts: AddGitRepoOptions) GitRepo {
    const normalized_repo = normalizeGitRepo(b, opts.git_repo);
    const commit_key = opts.commit orelse "head";
    const prefix_path = b.cache_root.join(b.allocator, &.{
        opts.cache_namespace,
        normalized_repo,
        commit_key,
    }) catch @panic("OOM");
    const source_root_path = if (opts.source_subdir.len == 0 or std.mem.eql(u8, opts.source_subdir, "."))
        prefix_path
    else
        joinPath(b, prefix_path, opts.source_subdir);

    const ensure = b.addSystemCommand(&.{"/bin/sh"});
    ensure.addFileArg(b.path("build/git_repo_ensure.sh"));
    ensure.addArg(prefix_path);
    ensure.addArg(opts.git_repo);
    ensure.addArg(opts.commit orelse "");
    ensure.setName("git-repo.ensure");

    const graph = b.allocator.create(GitRepo.EnsureGraph) catch @panic("OOM");
    graph.* = .{
        .ready = std.Build.Step.init(.{
            .id = .custom,
            .name = b.fmt("git-repo.ready.{s}.{s}", .{ normalized_repo, commit_key }),
            .owner = b,
        }),
        .tail = &ensure.step,
    };
    graph.ready.dependOn(&ensure.step);

    return .{
        .b = b,
        .steps = .{ .graph = graph },
        .git_repo = opts.git_repo,
        .commit = opts.commit,
        .cache_namespace = opts.cache_namespace,
        .repo_key = normalized_repo,
        .commit_key = commit_key,
        .source_subdir = opts.source_subdir,
        .prefix_path = prefix_path,
        .source_root_path = source_root_path,
    };
}

fn normalizeGitRepo(b: *std.Build, git_repo: []const u8) []const u8 {
    var repo = git_repo;
    if (std.mem.startsWith(u8, repo, "https://")) {
        repo = repo["https://".len..];
    } else if (std.mem.startsWith(u8, repo, "http://")) {
        repo = repo["http://".len..];
    } else if (std.mem.startsWith(u8, repo, "ssh://")) {
        repo = repo["ssh://".len..];
    } else if (std.mem.startsWith(u8, repo, "git@")) {
        repo = repo["git@".len..];
        if (std.mem.indexOfScalar(u8, repo, ':')) |idx| {
            repo = b.fmt("{s}/{s}", .{ repo[0..idx], repo[idx + 1 ..] });
        }
    }
    if (std.mem.endsWith(u8, repo, ".git")) {
        repo = repo[0 .. repo.len - ".git".len];
    }
    return repo;
}

fn joinPath(b: *std.Build, base: []const u8, sub_path: []const u8) []const u8 {
    return std.fs.path.join(b.allocator, &.{ base, sub_path }) catch @panic("OOM");
}

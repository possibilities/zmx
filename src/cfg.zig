/// Cfg is zmx's configuration container.
///
/// The purpose of this container is to hold anything that can be modified by the user.
pub const Cfg = @This();

const std = @import("std");
const build_options = @import("build_options");
const lib_posix = @import("posix.zig");
const cross = @import("cross.zig");

/// Built as fmx's Companion (`-Dcompanion`), the default directory is the one
/// fmx keeps its sessions in — under `/tmp` itself, not `TMPDIR` or
/// `XDG_RUNTIME_DIR`, because macOS caps a socket path near 104 bytes and
/// fmx's session names carry a 32-character id — with the logs under it.
/// `ZMX_DIR` still overrides, which is how fmx's tests keep a private one.
pub const companion: bool = build_options.companion;

/// A Companion's directory is private: fmx creates it 0700 and refuses one
/// that others can read, so a `fmx-zmx` run by hand before fmx ever started
/// must not leave a directory fmx will then reject.
pub const default_dir_mode: u32 = if (companion) 0o700 else 0o750;
pub const default_log_mode: u32 = if (companion) 0o600 else 0o640;

socket_dir: []const u8,
log_dir: []const u8,
max_scrollback_lines: usize = default_scrollback_lines,
dir_mode: u32 = default_dir_mode,
log_mode: u32 = default_log_mode,
tracked_envs: []const u8 = "DISPLAY,SSH_AUTH_SOCK,SSH_AGENT_PID,SSH_CONNECTION,WINDOWID,XAUTHORITY,KITTY_LISTEN_ON,KITTY_PID,KITTY_WINDOW_ID",

pub const default_scrollback_lines: usize = 10_000;

pub fn init(alloc: std.mem.Allocator, io: std.Io) !Cfg {
    const socket_dir = try socketDir(alloc);
    errdefer alloc.free(socket_dir);
    const log_dir = try logDir(alloc);
    errdefer alloc.free(log_dir);

    const dir_mode = if (lib_posix.getenv("ZMX_DIR_MODE")) |m|
        std.fmt.parseInt(u32, m, 8) catch default_dir_mode
    else
        default_dir_mode;

    const log_mode = if (lib_posix.getenv("ZMX_LOG_MODE")) |m|
        std.fmt.parseInt(u32, m, 8) catch default_log_mode
    else
        default_log_mode;

    // Lines of scrollback the shadow terminal keeps, which is what a restore
    // can replay. Unset or unparsable keeps the default.
    const scrollback = if (lib_posix.getenv("ZMX_SCROLLBACK_LINES")) |m|
        std.fmt.parseInt(usize, m, 10) catch default_scrollback_lines
    else
        default_scrollback_lines;

    var cfg = Cfg{
        .socket_dir = socket_dir,
        .log_dir = log_dir,
        .dir_mode = dir_mode,
        .log_mode = log_mode,
        .max_scrollback_lines = scrollback,
    };

    try cfg.mkdir(io);

    return cfg;
}

fn socketDir(alloc: std.mem.Allocator) ![]const u8 {
    const tmpdir = std.mem.trimEnd(u8, lib_posix.getenv("TMPDIR") orelse "/tmp", "/");
    const uid = lib_posix.getuid();

    const socket_dir: []const u8 = if (lib_posix.getenv("ZMX_DIR")) |zmxdir|
        try alloc.dupe(u8, zmxdir)
    else if (companion)
        try std.fmt.allocPrint(alloc, "/tmp/fmx-{d}/zmx", .{uid})
    else if (lib_posix.getenv("XDG_RUNTIME_DIR")) |xdg_runtime|
        try std.fmt.allocPrint(alloc, "{s}/zmx", .{xdg_runtime})
    else
        try std.fmt.allocPrint(alloc, "{s}/zmx-{d}", .{ tmpdir, uid });

    return socket_dir;
}

fn logDir(alloc: std.mem.Allocator) ![]const u8 {
    const log_dir = if (lib_posix.getenv("ZMX_DIR")) |zmxdir|
        try std.fmt.allocPrint(alloc, "{s}/logs", .{zmxdir})
    else if (companion)
        try std.fmt.allocPrint(alloc, "/tmp/fmx-{d}/zmx/logs", .{lib_posix.getuid()})
    else if (lib_posix.getenv("XDG_STATE_HOME")) |xdg_state_home|
        try std.fmt.allocPrint(alloc, "{s}/zmx/logs", .{xdg_state_home})
    else if (lib_posix.getenv("HOME")) |home_dir|
        try std.fmt.allocPrint(alloc, "{s}/.local/state/zmx/logs", .{home_dir})
    else fallback: {
        // This is the last resort: falling back to /tmp/$UID if HOME is unset.
        const tmpdir = std.mem.trimEnd(u8, lib_posix.getenv("TMPDIR") orelse "/tmp", "/");
        const uid = lib_posix.getuid();
        break :fallback try std.fmt.allocPrint(alloc, "{s}/zmx-{d}", .{ tmpdir, uid });
    };

    return log_dir;
}

pub fn deinit(self: *Cfg, alloc: std.mem.Allocator) void {
    if (self.socket_dir.len > 0) alloc.free(self.socket_dir);
    if (self.log_dir.len > 0) alloc.free(self.log_dir);
}

pub fn mkdir(self: *Cfg, io: std.Io) !void {
    const sock_perms = std.Io.Dir.Permissions.fromMode(@intCast(self.dir_mode));
    try mkdirAll(io, self.socket_dir, sock_perms);
    const log_perms = std.Io.Dir.Permissions.fromMode(@intCast(self.dir_mode));
    try mkdirAll(io, self.log_dir, log_perms);
}

fn mkdirAll(io: std.Io, sub_dir_path: []const u8, permissions: std.Io.Dir.Permissions) !void {
    var it = std.fs.path.componentIterator(sub_dir_path);
    var component = it.last() orelse return error.BadPathName;
    while (true) {
        std.Io.Dir.createDirAbsolute(io, component.path, permissions) catch |err| switch (err) {
            error.PathAlreadyExists => {
                // Dangling symlinks return PathAlreadyExists on mkdir but fail on traversal,
                // causing an infinite loop between previous() and next().
                const stat = std.Io.Dir.cwd().statFile(io, component.path, .{}) catch |e| switch (e) {
                    error.FileNotFound => return error.NotDir,
                    else => |stat_err| return stat_err,
                };
                if (stat.kind != .directory) return error.NotDir;
            },
            error.FileNotFound => |e| {
                component = it.previous() orelse return e;
                continue;
            },
            else => |e| return e,
        };
        component = it.next() orelse return;
    }
}

test "Cfg.init uses default modes when env vars are not set" {
    const alloc = std.testing.allocator;

    // Ensure they are not set
    _ = cross.c.unsetenv("ZMX_DIR_MODE");
    _ = cross.c.unsetenv("ZMX_LOG_MODE");

    var cfg = try Cfg.init(alloc, std.testing.io);
    defer cfg.deinit(alloc);

    try std.testing.expectEqual(default_dir_mode, cfg.dir_mode);
    try std.testing.expectEqual(default_log_mode, cfg.log_mode);
}

test "Cfg.init uses custom modes from env vars" {
    const alloc = std.testing.allocator;

    // Set custom octal values
    _ = cross.c.setenv("ZMX_DIR_MODE", "770", 1);
    _ = cross.c.setenv("ZMX_LOG_MODE", "660", 1);
    defer {
        _ = cross.c.unsetenv("ZMX_DIR_MODE");
        _ = cross.c.unsetenv("ZMX_LOG_MODE");
    }

    var cfg = try Cfg.init(alloc, std.testing.io);
    defer cfg.deinit(alloc);

    try std.testing.expectEqual(@as(u32, 0o770), cfg.dir_mode);
    try std.testing.expectEqual(@as(u32, 0o660), cfg.log_mode);
}

test "mkdirAll fails on dangling symlink instead of looping" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const alloc = std.testing.allocator;
    const tmp_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_path);

    try tmp.dir.symLink(std.testing.io, "nonexistent", "broken_link", .{});

    const target_path = try std.fs.path.join(alloc, &.{ tmp_path, "broken_link", "sub" });
    defer alloc.free(target_path);

    const perms = std.Io.Dir.Permissions.fromMode(0o750);
    try std.testing.expectError(error.NotDir, mkdirAll(std.testing.io, target_path, perms));
}

test "Cfg.init reads ZMX_SCROLLBACK_LINES, ignoring nonsense" {
    const alloc = std.testing.allocator;
    _ = cross.c.setenv("ZMX_SCROLLBACK_LINES", "50000", 1);
    defer _ = cross.c.unsetenv("ZMX_SCROLLBACK_LINES");
    {
        var cfg = try Cfg.init(alloc, std.testing.io);
        defer cfg.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 50000), cfg.max_scrollback_lines);
    }
    _ = cross.c.setenv("ZMX_SCROLLBACK_LINES", "lots", 1);
    {
        var cfg = try Cfg.init(alloc, std.testing.io);
        defer cfg.deinit(alloc);
        try std.testing.expectEqual(default_scrollback_lines, cfg.max_scrollback_lines);
    }
}

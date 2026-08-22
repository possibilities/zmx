//! `zmx create`: start a session headlessly and report, in prose or JSON,
//! only once the command is running -- or exactly why it is not.
//!
//! This is the supervisor's surface. `attach` is an upsert that silently
//! drops the command when the name is taken and returns on a sleep; a
//! program that owns sessions needs the opposite on both counts: a taken
//! name is an error, and success means the child crossed `exec`.

const std = @import("std");
const Cfg = @import("cfg.zig");
const Daemon = @import("loop.zig").Daemon;
const daemonize = @import("daemonize.zig");
const label = @import("label.zig");
const socket = @import("socket.zig");
const util = @import("util.zig");

pub const Options = struct {
    /// Session name, before any `ZMX_SESSION_PREFIX`.
    name: []const u8,
    /// argv for the child, passed straight to `execvpe`. Never empty.
    command: []const []const u8,
    /// `k=v ...` the daemon is born with.
    labels: ?[]const u8 = null,
    /// One JSON object on stdout instead of prose.
    json: bool = false,
    /// How long to wait for the daemon's startup report.
    timeout_ms: u32 = Daemon.default_startup_timeout_ms,
    /// Working directory for the child, as the caller sees it.
    cwd: []const u8,
    shell: []const u8,
    /// Lines of scrollback the session keeps; null keeps the configured
    /// default (`ZMX_SCROLLBACK_LINES`, else 2000).
    scrollback_lines: ?usize = null,
};

/// Machine-readable failure names. Stable: fmx matches on them.
pub const Failure = enum {
    /// The name is empty, reserved, or holds a path separator.
    InvalidName,
    InvalidLabel,
    CommandRequired,
    NameTooLong,
    AlreadyExists,
    /// The socket exists but did not answer like a live or dead daemon.
    SessionUnreachable,
    /// The child could not be started; `detail` names the cause.
    ExecFailed,
    /// The daemon died before the child was set up.
    DaemonFailed,
    /// No report within `timeout_ms`. The session may still come up.
    Timeout,
    /// Anything else, named in `detail`.
    Internal,
};

const Report = struct {
    ok: bool,
    name: []const u8,
    socket_path: ?[]const u8 = null,
    pid: ?i32 = null,
    created_at: ?u64 = null,
    failure: ?Failure = null,
    message: []const u8 = "",
    detail: ?[]const u8 = null,
    timeout_ms: ?u32 = null,
};

/// Runs the command. Returns normally in the creating process after the
/// report is written (exit status is the caller's to set from the return);
/// in the daemon process it returns only when the session is over.
pub fn create(gpa: std.mem.Allocator, io: std.Io, cfg: *Cfg, opts: Options) !u8 {
    var msg_buf: [512]u8 = undefined;

    if (opts.command.len == 0) {
        return fail(io, opts, .{ .ok = false, .name = opts.name, .failure = .CommandRequired, .message = "a command is required" });
    }

    if (opts.labels) |kvs| {
        if (invalidLabel(kvs)) |bad| {
            const message = std.fmt.bufPrint(&msg_buf, "{s}: {s}", .{ describeLabelError(bad.err), bad.text }) catch "invalid label";
            return fail(io, opts, .{ .ok = false, .name = opts.name, .failure = .InvalidLabel, .message = message });
        }
    }

    const sesh = socket.getSeshName(gpa, opts.name) catch |err| switch (err) {
        error.SessionNameRequired => return fail(io, opts, .{ .ok = false, .name = opts.name, .failure = .InvalidName, .message = "a session name is required", .detail = @errorName(err) }),
        error.InvalidSessionName, error.SessionNameReserved => {
            const message = std.fmt.bufPrint(&msg_buf, "session name \"{s}\" cannot be used: {s}", .{ opts.name, @errorName(err) }) catch "invalid session name";
            return fail(io, opts, .{ .ok = false, .name = opts.name, .failure = .InvalidName, .message = message, .detail = @errorName(err) });
        },
        else => return err,
    };
    defer gpa.free(sesh);
    const socket_path = socket.getSocketPath(gpa, cfg.socket_dir, sesh) catch |err| switch (err) {
        error.NameTooLong => {
            const message = std.fmt.bufPrint(&msg_buf, "session name \"{s}\" is too long for a socket path under {s}", .{ sesh, cfg.socket_dir }) catch "session name too long";
            return fail(io, opts, .{ .ok = false, .name = sesh, .failure = .NameTooLong, .message = message });
        },
        error.OutOfMemory => return err,
    };
    // The daemon process frees it through `Daemon.deinit`; the creator
    // frees it here, after any report that names it has been written.
    var creator_owns_socket_path = true;
    defer if (creator_owns_socket_path) gpa.free(socket_path);

    if (opts.scrollback_lines) |lines| cfg.max_scrollback_lines = lines;

    var daemon = Daemon.init(io, cfg, sesh, socket_path);
    daemon.command = opts.command;
    daemon.setCwd(opts.cwd);
    daemon.shell = opts.shell;
    daemon.initial_labels = opts.labels;
    daemon.startup_timeout_ms = opts.timeout_ms;
    daemon.record_exit = true;
    std.log.info("socket path={s}", .{daemon.socket_path});

    const is_daemon = daemon.createSession(io) catch |err| switch (err) {
        error.AlreadyExists => {
            const message = std.fmt.bufPrint(&msg_buf, "session \"{s}\" already exists", .{sesh}) catch "session already exists";
            return fail(io, opts, .{ .ok = false, .name = sesh, .socket_path = socket_path, .failure = .AlreadyExists, .message = message });
        },
        error.SessionUnreachable => {
            const message = std.fmt.bufPrint(&msg_buf, "session \"{s}\" has a socket that neither answers nor refuses", .{sesh}) catch "session unreachable";
            return fail(io, opts, .{ .ok = false, .name = sesh, .socket_path = socket_path, .failure = .SessionUnreachable, .message = message });
        },
        else => {
            const message = std.fmt.bufPrint(&msg_buf, "could not create session \"{s}\": {s}", .{ sesh, @errorName(err) }) catch "could not create session";
            return fail(io, opts, .{ .ok = false, .name = sesh, .failure = .Internal, .message = message, .detail = @errorName(err) });
        },
    };
    if (is_daemon) {
        creator_owns_socket_path = false;
        return 0;
    }

    const report = daemon.startup orelse {
        return fail(io, opts, .{ .ok = false, .name = sesh, .failure = .Internal, .message = "no startup report", .detail = "MissingStartupReport" });
    };
    switch (report) {
        .ready => |pid| {
            try emit(io, opts, .{
                .ok = true,
                .name = sesh,
                .socket_path = socket_path,
                .pid = pid,
                .created_at = daemon.created_at,
            });
            return 0;
        },
        .exec_failed => |name| {
            const message = std.fmt.bufPrint(&msg_buf, "session \"{s}\": command failed to start: {s}", .{ sesh, name }) catch "command failed to start";
            return fail(io, opts, .{ .ok = false, .name = sesh, .failure = .ExecFailed, .message = message, .detail = name });
        },
        .daemon_failed => {
            const message = std.fmt.bufPrint(&msg_buf, "session \"{s}\": daemon exited before it was ready (see the log)", .{sesh}) catch "daemon exited before it was ready";
            return fail(io, opts, .{ .ok = false, .name = sesh, .failure = .DaemonFailed, .message = message });
        },
        .timeout => {
            const message = std.fmt.bufPrint(&msg_buf, "session \"{s}\": no startup report within {d}ms; it may still come up", .{ sesh, opts.timeout_ms }) catch "no startup report";
            return fail(io, opts, .{ .ok = false, .name = sesh, .socket_path = socket_path, .failure = .Timeout, .message = message, .timeout_ms = opts.timeout_ms });
        },
    }
}

fn fail(io: std.Io, opts: Options, report: Report) !u8 {
    try emit(io, opts, report);
    return 1;
}

fn emit(io: std.Io, opts: Options, report: Report) !void {
    var buf: [4096]u8 = undefined;
    if (opts.json) {
        var w = std.Io.File.stdout().writerStreaming(io, &buf);
        try writeJson(&w.interface, report);
        try w.interface.writeByte('\n');
        try w.interface.flush();
        return;
    }
    if (report.ok) {
        var w = std.Io.File.stdout().writerStreaming(io, &buf);
        try w.interface.print("session \"{s}\" created\n", .{report.name});
        try w.interface.flush();
    } else {
        var w = std.Io.File.stderr().writerStreaming(io, &buf);
        try w.interface.print("error: {s}\n", .{report.message});
        try w.interface.flush();
    }
}

/// One object, always with `ok` and `name`; the rest only when known, so a
/// reader never has to tell "absent" from "zero".
fn writeJson(w: *std.Io.Writer, report: Report) !void {
    var js: std.json.Stringify = .{ .writer = w };
    try js.beginObject();
    try js.objectField("ok");
    try js.write(report.ok);
    try js.objectField("name");
    try util.jsonText(&js, report.name);
    if (report.socket_path) |p| {
        try js.objectField("socketPath");
        try util.jsonText(&js, p);
    }
    if (report.pid) |pid| {
        try js.objectField("pid");
        try js.write(pid);
    }
    if (report.created_at) |t| {
        try js.objectField("createdAt");
        try js.write(t);
    }
    if (report.failure) |f| {
        try js.objectField("error");
        try js.write(@tagName(f));
        try js.objectField("message");
        try util.jsonText(&js, report.message);
    }
    if (report.detail) |d| {
        try js.objectField("detail");
        try util.jsonText(&js, d);
    }
    if (report.timeout_ms) |t| {
        try js.objectField("timeoutMs");
        try js.write(t);
    }
    try js.endObject();
}

pub const Args = struct {
    name: []const u8 = "",
    /// Index into argv of the command's first word; `argv.len` when none.
    command_start: usize = 0,
    labels: ?[]const u8 = null,
    json: bool = false,
    timeout_ms: u32 = Daemon.default_startup_timeout_ms,
    scrollback_lines: ?usize = null,
    want_help: bool = false,
    /// Set when a flag was malformed; the message says which.
    usage_error: ?[]const u8 = null,
};

/// Parses what follows `zmx create`. Flags are recognized only before the
/// session name; everything after it is the command, except that one
/// leading `--` is stripped so callers can keep a command starting with a
/// dash from being read as a flag.
pub fn parseArgs(argv: []const []const u8) Args {
    var parsed: Args = .{ .command_start = argv.len };
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            parsed.want_help = true;
            return parsed;
        }
        if (std.mem.eql(u8, arg, "--json")) {
            parsed.json = true;
            continue;
        }
        if (flagValue(argv, &i, "--labels")) |v| {
            parsed.labels = v orelse {
                parsed.usage_error = "--labels requires \"key=value ...\"";
                return parsed;
            };
            continue;
        }
        if (flagValue(argv, &i, "--timeout-ms")) |v| {
            const text = v orelse {
                parsed.usage_error = "--timeout-ms requires a number of milliseconds";
                return parsed;
            };
            parsed.timeout_ms = std.fmt.parseInt(u32, text, 10) catch {
                parsed.usage_error = "--timeout-ms requires a number of milliseconds";
                return parsed;
            };
            continue;
        }
        if (flagValue(argv, &i, "--scrollback-lines")) |v| {
            const text = v orelse {
                parsed.usage_error = "--scrollback-lines requires a number of lines";
                return parsed;
            };
            parsed.scrollback_lines = std.fmt.parseInt(usize, text, 10) catch {
                parsed.usage_error = "--scrollback-lines requires a number of lines";
                return parsed;
            };
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
            parsed.usage_error = "unknown flag before the session name";
            return parsed;
        }
        parsed.name = arg;
        i += 1;
        break;
    }
    if (i < argv.len and std.mem.eql(u8, argv[i], "--")) i += 1;
    parsed.command_start = i;
    return parsed;
}

/// `--flag value` or `--flag=value`. Returns null when `argv[i]` is not
/// this flag; `?null` when it is but has no value. Advances `i` past a
/// consumed value.
fn flagValue(argv: []const []const u8, i: *usize, comptime flag: []const u8) ??[]const u8 {
    const arg = argv[i.*];
    if (std.mem.startsWith(u8, arg, flag ++ "=")) return arg[flag.len + 1 ..];
    if (!std.mem.eql(u8, arg, flag)) return null;
    if (i.* + 1 >= argv.len) return @as(?[]const u8, null);
    i.* += 1;
    return argv[i.*];
}

test "parseArgs: flags before the name, command after it" {
    const argv: []const []const u8 = &.{ "--json", "--labels", "a=1 b=2", "--timeout-ms=250", "--scrollback-lines", "9000", "work", "--", "/bin/sh", "-c", "echo --json" };
    const p = parseArgs(argv);
    try std.testing.expect(p.json);
    try std.testing.expectEqualStrings("a=1 b=2", p.labels.?);
    try std.testing.expectEqual(@as(u32, 250), p.timeout_ms);
    try std.testing.expectEqual(@as(?usize, 9000), p.scrollback_lines);
    try std.testing.expectEqualStrings("work", p.name);
    try std.testing.expectEqual(@as(usize, 8), p.command_start);
    try std.testing.expect(p.usage_error == null);
}

test "parseArgs: the separator is optional and only stripped once" {
    const with: []const []const u8 = &.{ "x", "--", "--", "cmd" };
    try std.testing.expectEqual(@as(usize, 2), parseArgs(with).command_start);
    const without: []const []const u8 = &.{ "x", "cmd", "--json" };
    const p = parseArgs(without);
    try std.testing.expectEqual(@as(usize, 1), p.command_start);
    try std.testing.expect(!p.json);
}

test "parseArgs: reports malformed flags and no command" {
    try std.testing.expect(parseArgs(&.{"--labels"}).usage_error != null);
    try std.testing.expect(parseArgs(&.{ "--timeout-ms", "soon", "x" }).usage_error != null);
    try std.testing.expect(parseArgs(&.{ "--scrollback-lines", "many", "x" }).usage_error != null);
    try std.testing.expect(parseArgs(&.{ "--bogus", "x" }).usage_error != null);
    const bare = parseArgs(&.{"x"});
    try std.testing.expectEqual(bare.command_start, @as(usize, 1));
    try std.testing.expect(parseArgs(&.{ "x", "-h" }).want_help == false);
    try std.testing.expect(parseArgs(&.{"-h"}).want_help);
}

const InvalidLabel = struct { err: label.LabelError, text: []const u8 };

fn invalidLabel(labels: []const u8) ?InvalidLabel {
    var kvs = label.LabelIterator.init(labels);
    while (kvs.next()) |kv| {
        label.assertLabel(kv.key, kv.value) catch |err| {
            return .{ .err = err, .text = switch (err) {
                error.LabelValueInvalidChar => kv.value,
                else => kv.key,
            } };
        };
    }
    return null;
}

fn describeLabelError(err: label.LabelError) []const u8 {
    return switch (err) {
        error.LabelKeyEmpty => "label key cannot be empty",
        error.LabelKeyReservedName => "label key is a read-only built-in field",
        error.LabelKeyInvalidChar => "label keys can only contain [a-z, A-Z, 0-9, -_.]",
        error.LabelValueInvalidChar => "label values can only contain [a-z, A-Z, 0-9, -_.]",
    };
}

test "create report: success carries only what is known" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeJson(&out.writer, .{ .ok = true, .name = "x", .socket_path = "/tmp/d/x", .pid = 42, .created_at = 1700000000 });
    try std.testing.expectEqualStrings(
        "{\"ok\":true,\"name\":\"x\",\"socketPath\":\"/tmp/d/x\",\"pid\":42,\"createdAt\":1700000000}",
        out.written(),
    );
}

test "create report: failures name the error and say why" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeJson(&out.writer, .{ .ok = false, .name = "x", .failure = .ExecFailed, .message = "command failed to start: FileNotFound", .detail = "FileNotFound" });
    try std.testing.expectEqualStrings(
        "{\"ok\":false,\"name\":\"x\",\"error\":\"ExecFailed\",\"message\":\"command failed to start: FileNotFound\",\"detail\":\"FileNotFound\"}",
        out.written(),
    );

    out.clearRetainingCapacity();
    try writeJson(&out.writer, .{ .ok = false, .name = "a\"b", .failure = .Timeout, .message = "m", .timeout_ms = 5000 });
    try std.testing.expectEqualStrings(
        "{\"ok\":false,\"name\":\"a\\\"b\",\"error\":\"Timeout\",\"message\":\"m\",\"timeoutMs\":5000}",
        out.written(),
    );
}

test "create rejects the labels attach would" {
    try std.testing.expect(invalidLabel("a=1 b=2") == null);
    try std.testing.expectEqual(label.LabelError.LabelKeyReservedName, invalidLabel("name=x").?.err);
    try std.testing.expectEqual(label.LabelError.LabelValueInvalidChar, invalidLabel("a=b/c").?.err);
    try std.testing.expectEqualStrings("b/c", invalidLabel("a=b/c").?.text);
}

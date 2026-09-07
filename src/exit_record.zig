//! Exit records: how a session ended, kept on disk for a supervisor that was
//! not connected to be told.
//!
//! A connected client learns a child's exact status from the `Exit` frame.
//! A supervisor that was away finds only a missing socket, which says
//! nothing about code or signal. A session started by `create` therefore
//! leaves `<socket_dir>/exited/<name>.json` when it ends, written whole and
//! renamed into place. `inspect` and `list --json` report it as state
//! "exited"; `forget` removes it; `create` replaces a same-name record
//! before starting, so a live session never sits next to a stale one.

const std = @import("std");
const ipc = @import("ipc.zig");
const label = @import("label.zig");
const util = @import("util.zig");

pub const dir_name = "exited";

/// What is written. Field names are the JSON keys.
pub const Record = struct {
    name: []const u8,
    pid: i32,
    createdAt: u64,
    endedAt: u64,
    /// Null when the daemon could not observe how the child ended: after a
    /// handoff it is no longer the child's parent, so it learns that the
    /// session ended without learning its status. A reader that wants a
    /// number must decide what an unknown one means to it; writing a zero
    /// here would have made a failure look like a success.
    code: ?u8,
    signal: ?u8,
    reason: []const u8,
    /// `k=v k=v`, the form labels travel in everywhere else.
    labels: []const u8 = "",
};

pub fn reasonName(reason: ipc.Exit.Reason) []const u8 {
    return switch (reason) {
        .natural, .requested, .daemon_failure, .exec_failure => @tagName(reason),
        _ => "unknown",
    };
}

/// Path of the record for `name`, relative to the socket directory.
pub fn relPath(buf: []u8, name: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, dir_name ++ "/{s}.json", .{name});
}

/// One temp file per writer: two daemons of one name can tear down at
/// once (kill, create, kill inside the grace), and must not share it.
fn tmpRelPath(buf: []u8, name: []const u8, pid: i32) ![]const u8 {
    return std.fmt.bufPrint(buf, dir_name ++ "/.{s}.{d}.json.tmp", .{ name, pid });
}

/// Writes the record atomically: a reader sees the old file, the new file,
/// or none -- never a partial one. Creates the directory on first use, with
/// the socket directory's mode; the file takes the log mode.
pub fn write(io: std.Io, socket_dir: std.Io.Dir, dir_mode: u32, file_mode: u32, record: Record) !void {
    socket_dir.createDir(io, dir_name, std.Io.Dir.Permissions.fromMode(@intCast(dir_mode))) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var tmp_buf: [std.fs.max_name_bytes + 48]u8 = undefined;
    const tmp = try tmpRelPath(&tmp_buf, record.name, record.pid);
    var final_buf: [std.fs.max_name_bytes + 32]u8 = undefined;
    const final = try relPath(&final_buf, record.name);

    var out: [4096]u8 = undefined;
    var fbs: std.Io.Writer = .fixed(&out);
    try encode(&fbs, record);
    const bytes = fbs.buffered();

    {
        const file = try socket_dir.createFile(io, tmp, .{ .truncate = true, .permissions = std.Io.Dir.Permissions.fromMode(@intCast(file_mode)) });
        defer file.close(io);
        try file.writeStreamingAll(io, bytes);
        file.sync(io) catch {};
    }
    errdefer socket_dir.deleteFile(io, tmp) catch {};
    try std.Io.Dir.rename(socket_dir, tmp, socket_dir, final, io);
}

pub fn encode(w: *std.Io.Writer, record: Record) !void {
    var js: std.json.Stringify = .{ .writer = w };
    try js.beginObject();
    try js.objectField("name");
    try util.jsonText(&js, record.name);
    try js.objectField("pid");
    try js.write(record.pid);
    try js.objectField("createdAt");
    try js.write(record.createdAt);
    try js.objectField("endedAt");
    try js.write(record.endedAt);
    try js.objectField("code");
    try js.write(record.code);
    try js.objectField("signal");
    try js.write(record.signal);
    try js.objectField("reason");
    try util.jsonText(&js, record.reason);
    try js.objectField("labels");
    try util.jsonText(&js, record.labels);
    try js.endObject();
    try w.writeByte('\n');
}

pub const ReadError = error{ NotFound, Malformed } || std.mem.Allocator.Error;

/// Something other than a directory sits where the records live. Every
/// record is unreadable until it is moved; reported once, not as a
/// malformed record per name.
pub const BlockedError = error{RecordsBlocked};

/// Reads the record for `name`. A file that is not a record (truncated,
/// hand-edited, another version's shape) is `Malformed`, which callers
/// report rather than treat as absence: it is still evidence.
pub fn read(gpa: std.mem.Allocator, io: std.Io, socket_dir: std.Io.Dir, name: []const u8) ReadError!std.json.Parsed(Record) {
    var path_buf: [std.fs.max_name_bytes + 32]u8 = undefined;
    const path = relPath(&path_buf, name) catch return error.Malformed;
    const bytes = socket_dir.readFileAlloc(io, path, gpa, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return error.NotFound,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Malformed,
    };
    defer gpa.free(bytes);
    return std.json.parseFromSlice(Record, gpa, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Malformed,
    };
}

/// Removes the record. Idempotent: returns whether there was one.
pub fn remove(io: std.Io, socket_dir: std.Io.Dir, name: []const u8) !bool {
    var path_buf: [std.fs.max_name_bytes + 32]u8 = undefined;
    const path = try relPath(&path_buf, name);
    socket_dir.deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return false,
        else => return err,
    };
    return true;
}

/// Names of every record in the directory, without the `.json`. Temp files
/// from a write in progress are skipped.
pub fn names(gpa: std.mem.Allocator, io: std.Io, socket_dir: std.Io.Dir) !std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |n| gpa.free(n);
        out.deinit(gpa);
    }
    var dir = socket_dir.openDir(io, dir_name, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return out,
        else => return err,
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        // A write in progress, not a record. Names may start with a dot.
        if (std.mem.endsWith(u8, entry.name, ".tmp")) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        try out.append(gpa, try gpa.dupe(u8, entry.name[0 .. entry.name.len - ".json".len]));
    }
    return out;
}

test "exit record: encodes the shape a supervisor reads" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try encode(&w, .{
        .name = "fmx-abc",
        .pid = 77,
        .createdAt = 1700000000,
        .endedAt = 1700000042,
        .code = 7,
        .signal = 0,
        .reason = "natural",
        .labels = "instance=abc owner=fmx",
    });
    try std.testing.expectEqualStrings(
        "{\"name\":\"fmx-abc\",\"pid\":77,\"createdAt\":1700000000,\"endedAt\":1700000042,\"code\":7,\"signal\":0,\"reason\":\"natural\",\"labels\":\"instance=abc owner=fmx\"}\n",
        w.buffered(),
    );
}

test "exit record: an unobserved status is null, not a zero" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try encode(&w, .{
        .name = "fmx-abc",
        .pid = 77,
        .createdAt = 1700000000,
        .endedAt = 1700000042,
        .code = null,
        .signal = null,
        .reason = "natural",
    });
    try std.testing.expectEqualStrings(
        "{\"name\":\"fmx-abc\",\"pid\":77,\"createdAt\":1700000000,\"endedAt\":1700000042,\"code\":null,\"signal\":null,\"reason\":\"natural\",\"labels\":\"\"}\n",
        w.buffered(),
    );
}

test "exit record: a record written with a null status reads back as one" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init_single_threaded;
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try write(io, tmp.dir, 0o750, 0o640, .{
        .name = "migrated",
        .pid = 5,
        .createdAt = 1,
        .endedAt = 2,
        .code = null,
        .signal = null,
        .reason = "natural",
    });
    var parsed = try read(gpa, io, tmp.dir, "migrated");
    defer parsed.deinit();
    try std.testing.expectEqual(@as(?u8, null), parsed.value.code);
    try std.testing.expectEqual(@as(?u8, null), parsed.value.signal);
    try std.testing.expectEqualStrings("natural", parsed.value.reason);
}

test "exit record: write, read, list, remove, on a real directory" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init_single_threaded;
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try write(io, tmp.dir, 0o750, 0o640, .{ .name = "a", .pid = 1, .createdAt = 10, .endedAt = 20, .code = 0, .signal = 9, .reason = "requested" });
    try write(io, tmp.dir, 0o750, 0o640, .{ .name = "b", .pid = 2, .createdAt = 11, .endedAt = 21, .code = 3, .signal = 0, .reason = "natural", .labels = "k=v" });
    // Overwriting is a replace, not an append.
    try write(io, tmp.dir, 0o750, 0o640, .{ .name = "a", .pid = 1, .createdAt = 10, .endedAt = 25, .code = 0, .signal = 15, .reason = "requested" });
    // A dotted name is a name, not a temp file.
    try write(io, tmp.dir, 0o750, 0o640, .{ .name = ".dot", .pid = 3, .createdAt = 1, .endedAt = 2, .code = 0, .signal = 0, .reason = "natural" });

    var a = try read(gpa, io, tmp.dir, "a");
    defer a.deinit();
    try std.testing.expectEqual(@as(u8, 15), a.value.signal);
    try std.testing.expectEqual(@as(u64, 25), a.value.endedAt);
    try std.testing.expectEqualStrings("", a.value.labels);

    var b = try read(gpa, io, tmp.dir, "b");
    defer b.deinit();
    try std.testing.expectEqualStrings("k=v", b.value.labels);

    try std.testing.expectError(error.NotFound, read(gpa, io, tmp.dir, "c"));

    var listed = try names(gpa, io, tmp.dir);
    defer {
        for (listed.items) |n| gpa.free(n);
        listed.deinit(gpa);
    }
    try std.testing.expectEqual(@as(usize, 3), listed.items.len);

    try std.testing.expect(try remove(io, tmp.dir, "a"));
    try std.testing.expect(!try remove(io, tmp.dir, "a"));
    try std.testing.expectError(error.NotFound, read(gpa, io, tmp.dir, "a"));

    // Not a record: reported as such, not as absent.
    {
        const file = try tmp.dir.createFile(io, dir_name ++ "/bad.json", .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "{\"name\":");
    }
    try std.testing.expectError(error.Malformed, read(gpa, io, tmp.dir, "bad"));
}

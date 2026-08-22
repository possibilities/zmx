//! Discovery for programs: `list --json`, `inspect`, and `--where`.
//!
//! The interactive `list` sweeps up dead sessions as it goes, which is what
//! a person wants. A supervisor reconciling its records against what is on
//! disk wants the opposite: a refused socket is evidence that a session it
//! knew about ended while it was away, and reporting it must not delete it.
//! Nothing in this file mutates the socket directory.

const std = @import("std");
const Cfg = @import("cfg.zig");
const ipc = @import("ipc.zig");
const label = @import("label.zig");
const socket = @import("socket.zig");
const exit_record = @import("exit_record.zig");
const util = @import("util.zig");

/// `--where k=v`: keep only sessions whose labels say so. Several are
/// ANDed. A session whose labels could not be read (refused, unreachable)
/// cannot match and is dropped; list without `--where` to see those.
pub const Where = struct { key: []const u8, value: []const u8 };

pub const Options = struct {
    json: bool = false,
    where: []const Where = &.{},
};

pub const Args = struct {
    json: bool = false,
    short: bool = false,
    /// Session name, for `inspect`.
    name: []const u8 = "",
    where: std.ArrayList(Where) = .empty,
    want_help: bool = false,
    usage_error: ?[]const u8 = null,

    pub fn deinit(self: *Args, gpa: std.mem.Allocator) void {
        self.where.deinit(gpa);
    }
};

/// Parses the flags `list` and `inspect` share. `--where` takes `k=v` as
/// the next argument or after `=`; any bare word is the session name.
pub fn parseArgs(gpa: std.mem.Allocator, argv: []const []const u8) !Args {
    var parsed: Args = .{};
    errdefer parsed.deinit(gpa);
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
        if (std.mem.eql(u8, arg, "--short")) {
            parsed.short = true;
            continue;
        }
        const where_flag = "--where";
        var kv: ?[]const u8 = null;
        if (std.mem.startsWith(u8, arg, where_flag ++ "=")) {
            kv = arg[where_flag.len + 1 ..];
        } else if (std.mem.eql(u8, arg, where_flag)) {
            if (i + 1 >= argv.len) {
                parsed.usage_error = "--where requires key=value";
                return parsed;
            }
            i += 1;
            kv = argv[i];
        }
        if (kv) |text| {
            const eq = std.mem.indexOfScalar(u8, text, '=') orelse {
                parsed.usage_error = "--where requires key=value";
                return parsed;
            };
            if (eq == 0) {
                parsed.usage_error = "--where requires key=value";
                return parsed;
            }
            try parsed.where.append(gpa, .{ .key = text[0..eq], .value = text[eq + 1 ..] });
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
            parsed.usage_error = "unknown flag";
            return parsed;
        }
        parsed.name = arg;
    }
    return parsed;
}

/// What a session's socket told us. `absent` only comes from `inspect`,
/// which is asked about one name; `list` reports what exists.
/// `unreachable` is a keyword, hence the spelling; it serializes as
/// "unreachable".
pub const State = enum {
    live,
    refused,
    unreachable_,
    /// No socket, but an exit record says how it ended.
    exited,
    absent,

    pub fn name(self: State) []const u8 {
        return switch (self) {
            .unreachable_ => "unreachable",
            else => @tagName(self),
        };
    }
};

pub fn matches(entry: util.SessionEntry, where: []const Where) bool {
    if (where.len == 0) return true;
    const labels = entry.labels orelse return false;
    for (where) |w| {
        const found = label.getLabelValueFromPairs(w.key, labels) catch return false;
        if (!std.mem.eql(u8, found, w.value)) return false;
    }
    return true;
}

/// `zmx list --json` / `zmx list --where k=v`: every session in the
/// directory, as found, nothing touched.
pub fn list(gpa: std.mem.Allocator, io: std.Io, cfg: *Cfg, opts: Options) !void {
    var sessions = try util.get_session_entries(gpa, io, cfg.socket_dir, .{ .cleanup_stale = false });
    defer {
        for (sessions.items) |session| session.deinit(gpa);
        sessions.deinit(gpa);
    }
    std.mem.sort(util.SessionEntry, sessions.items, {}, util.SessionEntry.lessThan);

    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buf);
    const w = &stdout.interface;

    if (opts.json) {
        var js: std.json.Stringify = .{ .writer = w };
        try js.beginArray();
        for (sessions.items) |session| {
            if (!matches(session, opts.where)) continue;
            try writeEntry(&js, cfg.socket_dir, session, stateOf(session));
        }
        // Then what ended while nobody was connected. A name with a socket
        // is reported from the socket; its record, if any, is stale.
        var dir = try std.Io.Dir.openDirAbsolute(io, cfg.socket_dir, .{});
        defer dir.close(io);
        var exited = try exit_record.names(gpa, io, dir);
        defer {
            for (exited.items) |n| gpa.free(n);
            exited.deinit(gpa);
        }
        std.mem.sort([]const u8, exited.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);
        for (exited.items) |name| {
            var has_socket = false;
            for (sessions.items) |session| {
                if (std.mem.eql(u8, session.name, name)) has_socket = true;
            }
            if (has_socket) continue;
            var record = exit_record.read(gpa, io, dir, name) catch |err| switch (err) {
                error.Malformed => {
                    // Its labels cannot be read, so it matches no filter.
                    if (opts.where.len == 0) try writeMalformed(&js, cfg.socket_dir, name);
                    continue;
                },
                error.NotFound => continue,
                error.OutOfMemory => return err,
            };
            defer record.deinit();
            if (!labelsMatch(record.value.labels, opts.where)) continue;
            try writeExited(&js, cfg.socket_dir, record.value);
        }
        try js.endArray();
        try w.writeByte('\n');
        try w.flush();
        return;
    }

    const current_session = socket.getSeshNameFromEnv();
    for (sessions.items) |session| {
        if (!matches(session, opts.where)) continue;
        try util.writeSessionLine(w, session, false, current_session);
    }
    // Then what ended while nobody was connected, so a filtered list shows
    // the same sessions in either form.
    var dir = try std.Io.Dir.openDirAbsolute(io, cfg.socket_dir, .{});
    defer dir.close(io);
    var exited = try exit_record.names(gpa, io, dir);
    defer {
        for (exited.items) |n| gpa.free(n);
        exited.deinit(gpa);
    }
    std.mem.sort([]const u8, exited.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    for (exited.items) |name| {
        var has_socket = false;
        for (sessions.items) |session| {
            if (std.mem.eql(u8, session.name, name)) has_socket = true;
        }
        if (has_socket) continue;
        var record = exit_record.read(gpa, io, dir, name) catch continue;
        defer record.deinit();
        if (!labelsMatch(record.value.labels, opts.where)) continue;
        try w.print("  name={s}\tstate=exited\tpid={d}\tended={d}\texit_code={d}\tsignal={d}\treason={s}", .{
            record.value.name, record.value.pid, record.value.endedAt, record.value.code, record.value.signal, record.value.reason,
        });
        var kvs = label.LabelIterator.init(record.value.labels);
        while (kvs.next()) |kv| try w.print("\t{s}={s}", .{ kv.key, kv.value });
        try w.writeByte('\n');
    }
    try w.flush();
}

/// `zmx inspect <name>`: one session, including the answer "there is no
/// such session", which `list` has no row for.
pub fn inspect(gpa: std.mem.Allocator, io: std.Io, cfg: *Cfg, name: []const u8, opts: Options) !void {
    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buf);
    const w = &stdout.interface;

    var found: ?util.SessionEntry = null;
    defer if (found) |entry| entry.deinit(gpa);

    var sessions = try util.get_session_entries(gpa, io, cfg.socket_dir, .{ .cleanup_stale = false });
    defer sessions.deinit(gpa);
    for (sessions.items) |session| {
        if (found == null and std.mem.eql(u8, session.name, name)) {
            found = session;
        } else {
            session.deinit(gpa);
        }
    }

    const state: State = if (found) |entry| stateOf(entry) else .absent;
    if (found) |entry| {
        if (!matches(entry, opts.where)) {
            // Asked about a name that exists but is not the caller's: say
            // so the same way an absent one is said, so a filter cannot
            // be used to learn about sessions it excludes.
            found.?.deinit(gpa);
            found = null;
        }
    }

    // No socket: it may have ended while nobody was connected.
    var record: ?std.json.Parsed(exit_record.Record) = null;
    defer if (record) |*r| r.deinit();
    var malformed = false;
    if (found == null and state == .absent) {
        var dir = try std.Io.Dir.openDirAbsolute(io, cfg.socket_dir, .{});
        defer dir.close(io);
        if (exit_record.read(gpa, io, dir, name)) |r| {
            if (labelsMatch(r.value.labels, opts.where)) {
                record = r;
            } else {
                var owned = r;
                owned.deinit();
            }
        } else |err| switch (err) {
            error.NotFound => {},
            // Its labels cannot be read, so it matches no filter.
            error.Malformed => malformed = opts.where.len == 0,
            error.OutOfMemory => return err,
        }
    }

    if (opts.json) {
        var js: std.json.Stringify = .{ .writer = w };
        if (found) |entry| {
            try writeEntry(&js, cfg.socket_dir, entry, state);
        } else if (record) |r| {
            try writeExited(&js, cfg.socket_dir, r.value);
        } else if (malformed) {
            try writeMalformed(&js, cfg.socket_dir, name);
        } else {
            try js.beginObject();
            try js.objectField("name");
            try util.jsonText(&js, name);
            try js.objectField("state");
            try js.write(State.absent.name());
            try js.endObject();
        }
        try w.writeByte('\n');
        try w.flush();
        return;
    }

    if (record) |r| {
        try w.print("name={s}\nstate=exited\npid={d}\ncreated={d}\nended={d}\nexit_code={d}\nsignal={d}\nreason={s}\n", .{
            r.value.name, r.value.pid, r.value.createdAt, r.value.endedAt, r.value.code, r.value.signal, r.value.reason,
        });
        var kvs = label.LabelIterator.init(r.value.labels);
        while (kvs.next()) |kv| try w.print("label.{s}={s}\n", .{ kv.key, kv.value });
        try w.flush();
        return;
    }
    if (malformed) {
        try w.print("name={s}\nstate=exited\ndetail=MalformedExitRecord\n", .{name});
        try w.flush();
        return;
    }

    if (found) |entry| {
        try w.print("name={s}\nstate={s}\n", .{ entry.name, state.name() });
        if (entry.is_error) {
            try w.print("detail={s}\n", .{entry.error_name.?});
        } else {
            try w.print("pid={d}\nclients={d}\ncreated={d}\n", .{ entry.pid.?, entry.clients_len.?, entry.created_at });
            if (entry.cwd) |cwd| try w.print("cwd={s}\n", .{cwd});
            if (entry.cmd) |cmd| try w.print("cmd={s}\n", .{cmd});
            if (entry.labels) |labels| {
                var kvs = label.LabelIterator.init(labels);
                while (kvs.next()) |kv| try w.print("label.{s}={s}\n", .{ kv.key, kv.value });
            }
            if (entry.protocol) |p| try w.print("protocol={d}..{d}\n", .{ p.min_version, p.max_version });
        }
    } else {
        try w.print("name={s}\nstate=absent\n", .{name});
    }
    try w.flush();
}

fn labelsMatch(labels: []const u8, where: []const Where) bool {
    for (where) |w| {
        const found = label.getLabelValueFromPairs(w.key, labels) catch return false;
        if (!std.mem.eql(u8, found, w.value)) return false;
    }
    return true;
}

/// A session known only by its exit record.
fn writeExited(js: *std.json.Stringify, socket_dir: []const u8, record: exit_record.Record) !void {
    try js.beginObject();
    try js.objectField("name");
    try util.jsonText(js, record.name);
    try js.objectField("socketPath");
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    try util.jsonText(js, try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ socket_dir, record.name }));
    try js.objectField("state");
    try js.write(State.exited.name());
    try js.objectField("pid");
    try js.write(record.pid);
    try js.objectField("createdAt");
    try js.write(record.createdAt);
    try js.objectField("labels");
    try js.beginObject();
    var kvs = label.LabelIterator.init(record.labels);
    while (kvs.next()) |kv| {
        try js.objectField(kv.key);
        try js.write(kv.value);
    }
    try js.endObject();
    try js.objectField("lifecycle");
    try js.write("exited");
    try js.objectField("exit");
    try js.beginObject();
    try js.objectField("code");
    try js.write(record.code);
    try js.objectField("signal");
    try js.write(record.signal);
    try js.objectField("reason");
    try util.jsonText(js, record.reason);
    try js.objectField("endedAt");
    try js.write(record.endedAt);
    try js.endObject();
    try js.endObject();
}

/// An exit record that could not be read. Still reported: a supervisor
/// treating it as absence would forget a session that did end.
fn writeMalformed(js: *std.json.Stringify, socket_dir: []const u8, name: []const u8) !void {
    try js.beginObject();
    try js.objectField("name");
    try util.jsonText(js, name);
    try js.objectField("socketPath");
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    try util.jsonText(js, try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ socket_dir, name }));
    try js.objectField("state");
    try js.write(State.exited.name());
    try js.objectField("detail");
    try js.write("MalformedExitRecord");
    try js.endObject();
}

fn stateOf(entry: util.SessionEntry) State {
    if (!entry.is_error) return .live;
    if (std.mem.eql(u8, entry.error_name.?, "ConnectionRefused")) return .refused;
    return .unreachable_;
}

/// One session as JSON. Keys are present only when known, so a reader never
/// has to tell "unknown" from "zero". `labels` is an object; `protocol` is
/// null for a daemon that predates negotiation.
fn writeEntry(js: *std.json.Stringify, socket_dir: []const u8, entry: util.SessionEntry, state: State) !void {
    try js.beginObject();
    try js.objectField("name");
    try util.jsonText(js, entry.name);
    try js.objectField("socketPath");
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    try util.jsonText(js, try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ socket_dir, entry.name }));
    try js.objectField("state");
    try js.write(state.name());
    if (entry.is_error) {
        try js.objectField("detail");
        try js.write(entry.error_name.?);
        try js.endObject();
        return;
    }
    try js.objectField("pid");
    try js.write(entry.pid.?);
    try js.objectField("clients");
    try js.write(entry.clients_len.?);
    try js.objectField("createdAt");
    try js.write(entry.created_at);
    if (entry.cmd) |cmd| {
        try js.objectField("cmd");
        try util.jsonText(js, cmd);
    }
    if (entry.cwd) |cwd| {
        try js.objectField("cwd");
        try util.jsonText(js, cwd);
    }
    try js.objectField("labels");
    try js.beginObject();
    if (entry.labels) |labels| {
        var kvs = label.LabelIterator.init(labels);
        while (kvs.next()) |kv| {
            try js.objectField(kv.key);
            try js.write(kv.value);
        }
    }
    try js.endObject();
    // Task mode (`zmx run`) keeps the daemon up after the command ends and
    // reports the exit through Info; a session started any other way is
    // running for as long as it is live.
    const ended = entry.task_ended_at orelse 0;
    try js.objectField("lifecycle");
    try js.write(if (ended > 0) "exited" else "running");
    if (ended > 0) {
        try js.objectField("exit");
        try js.beginObject();
        try js.objectField("code");
        try js.write(entry.task_exit_code orelse 0);
        try js.objectField("endedAt");
        try js.write(ended);
        try js.endObject();
    }
    try js.objectField("protocol");
    if (entry.protocol) |p| {
        try js.beginObject();
        try js.objectField("minVersion");
        try js.write(p.min_version);
        try js.objectField("maxVersion");
        try js.write(p.max_version);
        try js.objectField("capabilities");
        try js.write(p.capabilities);
        try js.endObject();
    } else {
        try js.write(null);
    }
    try js.endObject();
}

test "writeExited: a session known only by its record" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer };
    try writeExited(&js, "/tmp/d", .{
        .name = "gone",
        .pid = 9,
        .createdAt = 100,
        .endedAt = 200,
        .code = 0,
        .signal = 15,
        .reason = "requested",
        .labels = "owner=fmx",
    });
    try std.testing.expectEqualStrings(
        "{\"name\":\"gone\",\"socketPath\":\"/tmp/d/gone\",\"state\":\"exited\",\"pid\":9,\"createdAt\":100,\"labels\":{\"owner\":\"fmx\"},\"lifecycle\":\"exited\",\"exit\":{\"code\":0,\"signal\":15,\"reason\":\"requested\",\"endedAt\":200}}",
        out.written(),
    );
}

test "parseArgs: --where in both forms, ANDed, plus a name" {
    const gpa = std.testing.allocator;
    var parsed = try parseArgs(gpa, &.{ "--json", "--where", "owner=fmx", "--where=profile=p1", "some-name" });
    defer parsed.deinit(gpa);
    try std.testing.expect(parsed.json);
    try std.testing.expectEqual(@as(usize, 2), parsed.where.items.len);
    try std.testing.expectEqualStrings("owner", parsed.where.items[0].key);
    try std.testing.expectEqualStrings("fmx", parsed.where.items[0].value);
    try std.testing.expectEqualStrings("p1", parsed.where.items[1].value);
    try std.testing.expectEqualStrings("some-name", parsed.name);
}

test "parseArgs: a where without key=value is a usage error" {
    const gpa = std.testing.allocator;
    for ([_][]const []const u8{ &.{"--where"}, &.{ "--where", "nope" }, &.{"--where==v"} }) |argv| {
        var parsed = try parseArgs(gpa, argv);
        defer parsed.deinit(gpa);
        try std.testing.expect(parsed.usage_error != null);
    }
}

test "matches: every where must hold, and unreadable labels never match" {
    const live = util.SessionEntry{
        .name = "x",
        .pid = 1,
        .clients_len = 0,
        .is_error = false,
        .error_name = null,
        .labels = "owner=fmx profile=p1",
        .created_at = 0,
        .task_ended_at = null,
        .task_exit_code = null,
    };
    try std.testing.expect(matches(live, &.{}));
    try std.testing.expect(matches(live, &.{.{ .key = "owner", .value = "fmx" }}));
    try std.testing.expect(matches(live, &.{ .{ .key = "owner", .value = "fmx" }, .{ .key = "profile", .value = "p1" } }));
    try std.testing.expect(!matches(live, &.{ .{ .key = "owner", .value = "fmx" }, .{ .key = "profile", .value = "p2" } }));
    try std.testing.expect(!matches(live, &.{.{ .key = "missing", .value = "" }}));

    var refused = live;
    refused.is_error = true;
    refused.error_name = "ConnectionRefused";
    refused.labels = null;
    try std.testing.expect(matches(refused, &.{}));
    try std.testing.expect(!matches(refused, &.{.{ .key = "owner", .value = "fmx" }}));
}

test "writeEntry: live, refused, and a finished task" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer };

    const live = util.SessionEntry{
        .name = "w1",
        .pid = 42,
        .clients_len = 1,
        .is_error = false,
        .error_name = null,
        .cmd = "/bin/sh -c 'sleep 30'",
        .cwd = "file://host/tmp",
        .labels = "owner=fmx",
        .created_at = 1700000000,
        .task_ended_at = 0,
        .task_exit_code = 0,
        .protocol = .{ .version = 1, .min_version = 1, .max_version = 1, .capabilities = 0 },
    };
    try writeEntry(&js, "/tmp/d", live, .live);
    try std.testing.expectEqualStrings(
        "{\"name\":\"w1\",\"socketPath\":\"/tmp/d/w1\",\"state\":\"live\",\"pid\":42,\"clients\":1,\"createdAt\":1700000000,\"cmd\":\"/bin/sh -c 'sleep 30'\",\"cwd\":\"file://host/tmp\",\"labels\":{\"owner\":\"fmx\"},\"lifecycle\":\"running\",\"protocol\":{\"minVersion\":1,\"maxVersion\":1,\"capabilities\":0}}",
        out.written(),
    );

    out.clearRetainingCapacity();
    js = .{ .writer = &out.writer };
    const refused = util.SessionEntry{
        .name = "dead",
        .pid = null,
        .clients_len = null,
        .is_error = true,
        .error_name = "ConnectionRefused",
        .created_at = 0,
        .task_ended_at = 0,
        .task_exit_code = 1,
    };
    try writeEntry(&js, "/tmp/d", refused, .refused);
    try std.testing.expectEqualStrings(
        "{\"name\":\"dead\",\"socketPath\":\"/tmp/d/dead\",\"state\":\"refused\",\"detail\":\"ConnectionRefused\"}",
        out.written(),
    );

    out.clearRetainingCapacity();
    js = .{ .writer = &out.writer };
    var task = live;
    task.labels = null;
    task.protocol = null;
    task.task_ended_at = 1700000100;
    task.task_exit_code = 7;
    try writeEntry(&js, "/tmp/d", task, .live);
    try std.testing.expectEqualStrings(
        "{\"name\":\"w1\",\"socketPath\":\"/tmp/d/w1\",\"state\":\"live\",\"pid\":42,\"clients\":1,\"createdAt\":1700000000,\"cmd\":\"/bin/sh -c 'sleep 30'\",\"cwd\":\"file://host/tmp\",\"labels\":{},\"lifecycle\":\"exited\",\"exit\":{\"code\":7,\"endedAt\":1700000100},\"protocol\":null}",
        out.written(),
    );
}
